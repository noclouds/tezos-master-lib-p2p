open Tezos_network_sandbox
open Internal_pervasives

let failf fmt = ksprintf (fun s -> fail (`Scenario_error s)) fmt

let ledger_prompt_notice state ~ef ?(button = `Checkmark) () =
  let button_str =
    match button with
    | `Checkmark -> "✔"
    | `X -> "❌"
    | `Both -> "❌ and ✔ at the same time" in
  Console.say state
    EF.(
      desc (shout "Ledger-prompt")
        (list [ef; wf "Press %s on the ledger." button_str]))

let assert_failure state msg f () =
  Console.say state EF.(wf "Asserting %s" msg)
  >>= fun () ->
  Asynchronous_result.bind_on_error
    (f () >>= fun _ -> return `Worked)
    ~f:(fun ~result _ -> return `Didn'tWork)
  >>= function `Worked -> failf "%s" msg | `Didn'tWork -> return ()

let failf fmt = ksprintf (fun s -> fail (`Scenario_error s)) fmt
let assert_ a = if a then return () else failf "Assertion failed"

let assert_eq to_string ~expected ~actual =
  if expected = actual then return ()
  else
    failf "Assertion failed: expected %s but got %s" (to_string expected)
      (to_string actual)

let rec ask state ef =
  Console.say state EF.(list [ef; wf " (y/n)?"])
  >>= fun () ->
  Lwt_exception.catch Lwt_io.read_char Lwt_io.stdin
  >>= function
  | 'y' | 'Y' -> return true | 'n' | 'N' -> return false | _ -> ask state ef

let ask_assert state ef () = ask state ef >>= fun b -> assert_ b

let with_ledger_prompt state message expectation ~f =
  ledger_prompt_notice state ()
    ~button:(match expectation with `Succeeds -> `Checkmark | `Fails -> `X)
    ~ef:
      EF.(
        list
          [ message; wf "\n\n"
          ; wf
              ( match expectation with
              | `Succeeds -> ">> ACCEPT THIS <<"
              | `Fails -> ">> REJECT THIS <<" ) ])
  >>= fun () ->
  match expectation with
  | `Succeeds ->
      f () >>= fun _ -> Console.say state EF.(wf "> Got response: ACCEPTED")
  | `Fails ->
      assert_failure state "expected failure" f ()
      >>= fun () -> Console.say state EF.(wf "> Got response: REJECTED")

let with_ledger_test_reject_and_succeed state ef f =
  with_ledger_prompt state ef `Fails ~f
  >>= fun () -> with_ledger_prompt state ef `Succeeds ~f

let assert_hwms state ~client ~uri ~main ~test =
  Console.say state
    EF.(wf "Asserting main HWM = %d and test HWM = %d" main test)
  >>= fun () ->
  Tezos_client.Ledger.get_hwm state ~client ~uri
  >>= fun {main= main_actual; test= test_actual; _} ->
  assert_eq string_of_int ~actual:main_actual ~expected:main
  >>= fun () -> assert_eq string_of_int ~actual:test_actual ~expected:test

let get_chain_id state ~client =
  Tezos_client.rpc state ~client `Get ~path:"/chains/main/chain_id"
  >>= (function
        | `String x -> return x
        | _ -> failf "Failed to parse chain_id JSON from node")
  >>= fun chain_id_string ->
  return (Tezos_crypto.Chain_id.of_b58check_exn chain_id_string)

let get_head_block_hash state ~client () =
  Tezos_client.rpc state ~client `Get ~path:"/chains/main/blocks/head/hash"
  >>= function
  | `String x -> return x
  | _ -> failf "Failed to parse block hash JSON from node"

let forge_endorsement state ~client ~chain_id ~level () =
  get_head_block_hash state ~client ()
  >>= fun branch ->
  let json =
    `O
      [ ("branch", `String branch)
      ; ( "contents"
        , `A
            [ `O
                [ ("kind", `String "endorsement")
                ; ("level", `Float (float_of_int level)) ] ] ) ] in
  Tezos_client.rpc state ~client
    ~path:"/chains/main/blocks/head/helpers/forge/operations"
    (`Post (Ezjsonm.to_string json))
  >>= function
  | `String operation_bytes ->
      let endorsement_magic_byte = "02" in
      return
        ( endorsement_magic_byte
        ^ (chain_id |> Tezos_crypto.Chain_id.to_hex |> Hex.show)
        ^ operation_bytes )
  | _ -> failf "Failed to forge operation or parse result"

let forge_delegation state ~client ~src ~dest ?(fee = 0.00126) () =
  get_head_block_hash state ~client ()
  >>= fun branch ->
  let json =
    `O
      [ ("branch", `String branch)
      ; ( "contents"
        , `A
            [ `O
                [ ("kind", `String "delegation")
                ; ("source", `String src)
                ; ( "fee"
                  , `String (string_of_int (int_of_float (fee *. 1000000.))) )
                ; ("counter", `String (string_of_int 30713))
                ; ("gas_limit", `String (string_of_int 10100))
                ; ("delegate", `String dest)
                ; ("storage_limit", `String (string_of_int 277)) ] ] ) ] in
  Tezos_client.rpc state ~client
    ~path:"/chains/main/blocks/head/helpers/forge/operations"
    (`Post (Ezjsonm.to_string json))
  >>= function
  | `String operation_bytes ->
      let magic_byte = "03" in
      return (magic_byte ^ operation_bytes)
  | _ -> failf "Failed to forge operation or parse result"

let sign state ~client ~bytes () =
  Tezos_client.successful_client_cmd state
    ~client:client.Tezos_client.Keyed.client
    ["sign"; "bytes"; "0x" ^ bytes; "for"; client.Tezos_client.Keyed.key_name]
  >>= fun _ -> return ()

let originate_account_from state ~client ~account =
  let orig_account_name =
    Tezos_protocol.Account.name account ^ "-originated-account" in
  Tezos_client.successful_client_cmd state ~client
    [ "originate"; "account"; orig_account_name; "for"
    ; Tezos_protocol.Account.name account
    ; "transferring"; string_of_int 1000; "from"
    ; Tezos_protocol.Account.name account
    ; "--burn-cap"; string_of_float 0.257 ]
  >>= fun _ -> return orig_account_name

let setup_baking_ledger state uri ~client ~protocol =
  Console.say state EF.(wf "Setting up the ledger device %S" uri)
  >>= fun () ->
  let key_name = "ledgered" in
  let baker = Tezos_client.Keyed.make client ~key_name ~secret_key:uri in
  let assert_baking_key x () =
    let to_string = function Some x -> x | None -> "<none>" in
    Console.say state
      EF.(wf "Asserting that the authorized key is %s" (to_string x))
    >>= fun () ->
    Tezos_client.Ledger.get_authorized_key state ~client ~uri
    >>= fun auth_key -> assert_eq to_string ~expected:x ~actual:auth_key in
  Tezos_client.Ledger.deauthorize_baking state ~client ~uri
  (* TODO: The following assertion doesn't confirm anything if the ledger was already not authorized to bake. *)
  >>= assert_baking_key None
  >>= fun () ->
  Tezos_client.Ledger.show_ledger state ~client ~uri
  >>= fun account ->
  with_ledger_test_reject_and_succeed state
    EF.(
      wf
        "Importing %S in client `%s`. The ledger should be prompting for \
         acknowledgment to provide the public key of %s"
        uri client.Tezos_client.id
        (Tezos_protocol.Account.pubkey_hash account))
    (fun () ->
      Tezos_client.Keyed.initialize state baker >>= fun _ -> return ())
  >>= assert_failure state "baking before setup should fail" (fun () ->
          Tezos_client.Keyed.bake state baker "Baked by ledger")
  >>= assert_failure state "endorsing before setup should fail" (fun () ->
          Tezos_client.Keyed.endorse state baker "Endorsed by ledger")
  >>= fun () ->
  let test_invalid_delegations () =
    let ledger_pkh = Tezos_protocol.Account.pubkey_hash account in
    let other_pkh =
      Tezos_protocol.Account.pubkey_hash
        (fst (List.last_exn protocol.Tezos_protocol.bootstrap_accounts)) in
    let cases =
      [ (ledger_pkh, other_pkh, "ledger to another account")
      ; (other_pkh, ledger_pkh, "another account to ledger")
      ; (other_pkh, other_pkh, "another account to another account") ] in
    List_sequential.iter cases ~f:(fun (src, dest, msg) ->
        forge_delegation state ~client ~src ~dest ()
        >>= fun forged_delegation_bytes ->
        assert_failure state
          (sprintf "signing a delegation from %s (%s to %s) should fail" msg
             src dest)
          (sign state ~client:baker ~bytes:forged_delegation_bytes)
          ()) in
  test_invalid_delegations ()
  >>= fun () ->
  with_ledger_test_reject_and_succeed state
    EF.(
      wf
        "Setting up %S for baking.\n\
         Address: %S\n\
         Chain: mainnet\n\
         Main HWM: 0\n\
         Test HWM: 0"
        uri
        (Tezos_protocol.Account.pubkey_hash account))
    (fun () ->
      Tezos_client.successful_client_cmd state ~client
        [ "setup"; "ledger"; "to"; "bake"; "for"; key_name; "--main-hwm"; "0"
        ; "--test-hwm"; "0" ])
  >>= assert_failure state
        "signing a 'Withdraw delegate' operation in Baking App should fail"
        (fun () ->
          Tezos_client.successful_client_cmd state ~client
            [ "--wait"; "none"; "withdraw"; "delegate"; "from"
            ; Tezos_protocol.Account.pubkey_hash account ])
  >>= assert_baking_key (Some uri)
  >>= test_invalid_delegations
  >>= fun () -> return (baker, account)

let run state ~node_exec ~client_exec ~admin_exec ~size ~base_port ~uri
    ~enable_deterministic_nonce_tests () =
  Helpers.clear_root state
  >>= fun () ->
  Interactive_test.Pauser.generic state
    EF.[af "Ready to start"; af "Root path deleted."]
  >>= fun () ->
  let ledger_client = Tezos_client.no_node_client ~exec:client_exec in
  Tezos_client.Ledger.show_ledger state ~client:ledger_client ~uri
  >>= fun ledger_account ->
  let protocol =
    let open Tezos_protocol in
    let d = default () in
    { d with
      time_between_blocks= [1; 2]
    ; bootstrap_accounts=
        (ledger_account, 1_000_000_000_000L)
        :: List.map ~f:(fun (a, _) -> (a, 1_000L)) d.bootstrap_accounts } in
  Test_scenario.network_with_protocol ~protocol ~size ~base_port state
    ~node_exec ~client_exec
  >>= fun (nodes, protocol) ->
  let make_admin = Tezos_admin_client.of_client ~exec:admin_exec in
  Interactive_test.Pauser.add_commands state
    Interactive_test.Commands.(
      all_defaults state ~nodes
      @ [ secret_keys state ~protocol
        ; Log_recorder.Operations.show_all state
        ; arbitrary_command_on_clients state ~command_names:["all-clients"]
            ~make_admin
            ~clients:
              (List.map nodes ~f:(Tezos_client.of_node ~exec:client_exec)) ]) ;
  Interactive_test.Pauser.generic state EF.[af "About to really start playing"]
  >>= fun () ->
  let client n =
    Tezos_client.of_node ~exec:client_exec (List.nth_exn nodes n) in
  let assert_hwms_ ~main ~test () =
    assert_hwms state ~client:(client 0) ~uri ~main ~test in
  let set_hwm_ level () =
    with_ledger_prompt state
      EF.(wf "Setting HWM to %d" level)
      `Succeeds
      ~f:(fun () ->
        Tezos_client.Ledger.set_hwm state ~client:(client 0) ~uri ~level) in
  get_chain_id state ~client:(client 0)
  >>= fun chain_id ->
  setup_baking_ledger state uri ~client:(client 0) ~protocol
  >>= fun (baker, ledger_account) ->
  Interactive_test.Pauser.add_commands state
    Interactive_test.Commands.
      [ arbitrary_command_on_clients state ~command_names:["baker"] ~make_admin
          ~clients:[baker.Tezos_client.Keyed.client] ] ;
  let bake () = Tezos_client.Keyed.bake state baker "Baked by ledger" in
  let endorse () =
    Tezos_client.Keyed.endorse state baker "Endorsed by ledger" in
  let ask_hwm ~main ~test () =
    assert_hwms_ ~main ~test ()
    >>= ask_assert state
          EF.(wf "Is 'Chain' = %S and 'Last Block Level' = %d" "mainnet" main)
  in
  ( if enable_deterministic_nonce_tests then
    (* Test determinism of nonces *)
    Tezos_client.Keyed.generate_nonce state baker "this"
    >>= fun thisNonce1 ->
    Tezos_client.Keyed.generate_nonce state baker "that"
    >>= fun thatNonce1 ->
    Tezos_client.Keyed.generate_nonce state baker "this"
    >>= fun thisNonce2 ->
    Tezos_client.Keyed.generate_nonce state baker "that"
    >>= fun thatNonce2 ->
    assert_eq (fun x -> x) ~expected:thisNonce1 ~actual:thisNonce2
    >>= fun () ->
    assert_eq (fun x -> x) ~expected:thatNonce1 ~actual:thatNonce2
    >>= fun () -> assert_ (thisNonce1 <> thatNonce1)
  else return () )
  >>= fun () ->
  assert_failure state
    "originating an account from the Tezos Baking app should fail"
    (fun () ->
      originate_account_from state ~client:(client 0) ~account:ledger_account
      >>= fun _ -> return ())
    ()
  >>= fun () ->
  let fee = 0.00126 in
  let ledger_pkh = Tezos_protocol.Account.pubkey_hash ledger_account in
  forge_delegation state ~client:(client 0) () ~src:ledger_pkh ~dest:ledger_pkh
    ~fee
  >>= fun forged_delegation_bytes ->
  with_ledger_test_reject_and_succeed state
    EF.(wf "Self delegating address %s with fee %f" ledger_pkh fee)
    (sign state ~client:baker ~bytes:forged_delegation_bytes)
  >>= bake >>= ask_hwm ~main:2 ~test:0
  >>= fun () ->
  (let level = 1 in
   with_ledger_test_reject_and_succeed state
     EF.(wf "Setting HWM to %d" level)
     (fun () ->
       Tezos_client.Ledger.set_hwm state ~client:(client 0) ~uri ~level))
  >>= assert_hwms_ ~main:1 ~test:1
  >>= bake
  >>= assert_hwms_ ~main:3 ~test:1
  >>= set_hwm_ 4
  >>= assert_hwms_ ~main:4 ~test:4
  >>= assert_failure state "endorsing a level beneath HWM should fail" endorse
  >>= assert_failure state "baking a level beneath HWM should fail" bake
  >>= set_hwm_ 3 >>= bake
  >>= assert_hwms_ ~main:4 ~test:3
  >>= endorse
  >>= assert_failure state "endorsing same block twice should not work" endorse
  >>= assert_hwms_ ~main:4 ~test:3
  >>= bake
  >>= assert_hwms_ ~main:5 ~test:3
  >>= forge_endorsement state ~client:baker.client ~chain_id ~level:1
  >>= fun endorsement_at_low_level_bytes ->
  assert_failure state "endorsing-after-baking a level beneath HWM should fail"
    (sign state ~client:baker ~bytes:endorsement_at_low_level_bytes)
    ()
  >>= assert_hwms_ ~main:5 ~test:3
  (* HWM has not changed *)
  >>= endorse
  (* HWM still has not changed *)
  >>= assert_hwms_ ~main:5 ~test:3
  (* Forge an endorsement on a different chain *)
  >>= fun () ->
  let other_chain_id = "NetXSzLHKwSumh7" in
  Console.say state
    EF.(
      wf "Signing a forged endorsement on a different chain: %s" other_chain_id)
  >>= forge_endorsement state ~client:baker.client
        ~chain_id:(Tezos_crypto.Chain_id.of_b58check_exn other_chain_id)
        ~level:4
  >>= fun endorsement_on_different_chain_bytes ->
  sign state ~client:baker ~bytes:endorsement_on_different_chain_bytes ()
  (* Only the test HWM has changed *)
  >>= assert_hwms_ ~main:5 ~test:4
  >>= fun () ->
  Loop.n_times 5 (fun _ -> bake ())
  >>= ask_hwm ~main:10 ~test:4
  >>= fun () ->
  Tezos_client.Ledger.deauthorize_baking state ~client:(client 0) ~uri
  >>= assert_failure state "baking after deauthorization should fail" bake
  >>= assert_failure state "endorsing after deauthorization should fail"
        endorse

let cmd ~pp_error () =
  let open Cmdliner in
  let open Term in
  Test_command_line.Run_command.make ~pp_error
    ( pure
        (fun uri
             node_exec
             client_exec
             admin_exec
             size
             (`Base_port base_port)
             no_deterministic_nonce_tests
             state
             ->
          ( state
          , Interactive_test.Pauser.run_test ~pp_error state
              (run state ~node_exec ~size ~admin_exec ~base_port ~client_exec
                 ~enable_deterministic_nonce_tests:
                   (not no_deterministic_nonce_tests)
                 ~uri) ))
    $ Arg.(
        required
          (pos 0 (some string) None
             (info [] ~docv:"LEDGER-URI" ~doc:"ledger:// URI")))
    $ Tezos_executable.cli_term `Node "tezos"
    $ Tezos_executable.cli_term `Client "tezos"
    $ Tezos_executable.cli_term `Admin "tezos"
    $ Arg.(value (opt int 5 (info ["size"; "S"] ~doc:"Size of the Network")))
    $ Arg.(
        pure (fun p -> `Base_port p)
        $ value
            (opt int 46_000
               (info ["base-port"; "P"] ~doc:"Base port number to build upon")))
    $ Arg.(
        value
          (flag
             (info
                ["no-deterministic-nonce-tests"]
                ~doc:"Disable tests for deterministic nonces")))
    $ Test_command_line.cli_state ~name:"ledger-baking" () )
    (let doc = "Interactive test exercising the Ledger Baking app features" in
     info ~doc "ledger-baking")
