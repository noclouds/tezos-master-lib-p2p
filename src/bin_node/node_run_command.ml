(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019 Nomadic Labs, <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Node_logging
open Genesis_chain

type error += Non_private_sandbox of P2p_addr.t
type error += RPC_Port_already_in_use of P2p_point.Id.t list

let () =
  register_error_kind
    `Permanent
    ~id:"main.run.non_private_sandbox"
    ~title:"Forbidden public sandbox"
    ~description:"A sandboxed node should not listen on a public address."
    ~pp:begin fun ppf addr ->
      Format.fprintf ppf
        "The node is configured to listen on a public address (%a), \
         while only 'private' networks are authorised with `--sandbox`.
           See `%s run --help` on how to change the listening address."
        Ipaddr.V6.pp addr Sys.argv.(0)
    end
    Data_encoding.(obj1 (req "addr" P2p_addr.encoding))
    (function Non_private_sandbox addr -> Some addr | _ -> None)
    (fun addr -> Non_private_sandbox addr);
  register_error_kind
    `Permanent
    ~id:"main.run.port_already_in_use"
    ~title:"Cannot start node: RPC port already in use"
    ~description:"Another tezos node is probably running on the same RPC port."
    ~pp:begin fun ppf addrlist ->
      Format.fprintf ppf
        "Another tezos node is probably running on one of these addresses (%a). \
         Please choose another RPC port."
        (Format.pp_print_list P2p_point.Id.pp) addrlist
    end
    Data_encoding.(obj1 (req "addrlist" (list P2p_point.Id.encoding)))
    (function | RPC_Port_already_in_use addrlist -> Some addrlist | _ -> None)
    (fun addrlist -> RPC_Port_already_in_use addrlist)

let (//) = Filename.concat

let init_node ?sandbox ?checkpoint (config : Node_config_file.t) =
  begin
    match sandbox with
    | None -> Lwt.return_none
    | Some sandbox_param ->
        match sandbox_param with
        | None -> Lwt.return_none
        | Some file ->
            Lwt_utils_unix.Json.read_file file >>= function
            | Error err ->
                lwt_warn
                  "Cannot parse sandbox parameters: %s" file >>= fun () ->
                lwt_debug "%a" pp_print_error err >>= fun () ->
                Lwt.return_none
            | Ok json ->
                Lwt.return_some json
  end >>= fun sandbox_param ->
  (* TODO "WARN" when pow is below our expectation. *)
  begin
    match config.p2p.discovery_addr with
    | None ->
        lwt_log_notice "No local peer discovery." >>= fun () ->
        return (None, None)
    | Some addr ->
        Node_config_file.resolve_discovery_addrs addr >>= function
        | [] ->
            failwith "Cannot resolve P2P discovery address: %S" addr
        | (addr, port) :: _ ->
            return (Some addr, Some port)
  end >>=? fun (discovery_addr, discovery_port) ->
  begin
    match config.p2p.listen_addr with
    | None ->
        lwt_log_notice "Not listening to P2P calls." >>= fun () ->
        return (None, None)
    | Some addr ->
        Node_config_file.resolve_listening_addrs addr >>= function
        | [] ->
            failwith "Cannot resolve P2P listening address: %S" addr
        | (addr, port) :: _ -> return (Some addr, Some port)
  end >>=? fun (listening_addr, listening_port) ->
  begin
    match listening_addr, sandbox with
    | Some addr, Some _
      when Ipaddr.V6.(compare addr unspecified) = 0 ->
        return_none
    | Some addr, Some _ when not (Ipaddr.V6.is_private addr) ->
        fail (Non_private_sandbox addr)
    | None, Some _ -> return_none
    | _ ->
        (Node_config_file.resolve_bootstrap_addrs
           config.p2p.bootstrap_peers) >>= fun trusted_points ->
        Node_identity_file.read
          (config.data_dir //
           Node_data_version.default_identity_file_name) >>=? fun identity ->
        lwt_log_notice
          "Peer's global id: %a"
          P2p_peer.Id.pp identity.peer_id >>= fun () ->
        let p2p_config : P2p.config =
          { listening_addr ;
            listening_port ;
            discovery_addr ;
            discovery_port ;
            trusted_points ;
            peers_file =
              (config.data_dir // "peers.json") ;
            private_mode = config.p2p.private_mode ;
            greylisting_config = config.p2p.greylisting_config ;
            identity ;
            proof_of_work_target =
              Crypto_box.make_target config.p2p.expected_pow ;
            disable_mempool = config.p2p.disable_mempool ;
            trust_discovered_peers = (sandbox_param <> None) ;
            disable_testchain = config.p2p.disable_testchain ;
          }
        in
        return_some (p2p_config, config.p2p.limits)
  end >>=? fun p2p_config ->
  let sandbox_param =
    Option.map ~f:(fun p -> ("sandbox_parameter", p)) sandbox_param in
  let node_config : Node.config = {
    genesis ;
    patch_context = Some (Patch_context.patch_context sandbox_param) ;
    store_root = Node_data_version.store_dir config.data_dir ;
    context_root = Node_data_version.context_dir config.data_dir ;
    p2p = p2p_config ;
    test_chain_max_tll = Some (48 * 3600) ; (* 2 days *)
    checkpoint ;
  } in
  Node.create
    ~sandboxed:(sandbox <> None)
    node_config
    config.shell.peer_validator_limits
    config.shell.block_validator_limits
    config.shell.prevalidator_limits
    config.shell.chain_validator_limits
    config.shell.history_mode

(* Add default accepted CORS headers *)
let sanitize_cors_headers ~default headers =
  List.map String.lowercase_ascii headers |>
  String.Set.of_list |>
  String.Set.(union (of_list default)) |>
  String.Set.elements

let launch_rpc_server
    (rpc_config : Node_config_file.rpc) node (addr, port) =
  let host = Ipaddr.V6.to_string addr in
  let dir = Node.build_rpc_directory node in
  let mode =
    match rpc_config.tls with
    | None -> `TCP (`Port port)
    | Some { cert ; key } ->
        `TLS (`Crt_file_path cert, `Key_file_path key,
              `No_password, `Port port) in
  lwt_log_notice
    "Starting a RPC server listening on %s:%d%s."
    host port
    (if rpc_config.tls = None then "" else " (TLS enabled)") >>= fun () ->
  let cors_headers =
    sanitize_cors_headers
      ~default:["Content-Type"] rpc_config.cors_headers in
  Lwt.catch begin fun () ->
    RPC_server.launch ~host mode dir
      ~media_types:Media_type.all_media_types
      ~cors:{ allowed_origins = rpc_config.cors_origins ;
              allowed_headers = cors_headers } >>= return
  end begin function
    | Unix.Unix_error(Unix.EADDRINUSE, "bind","") ->
        fail (RPC_Port_already_in_use [(addr,port)])
    | exn -> Lwt.return (error_exn exn)
  end

let init_rpc (rpc_config: Node_config_file.rpc) node =
  fold_right_s
    (fun addr acc ->
       Node_config_file.resolve_rpc_listening_addrs addr >>= function
       | [] ->
           failwith "Cannot resolve listening address: %S" addr
       | addrs ->
           fold_right_s
             (fun x a ->
                launch_rpc_server rpc_config node x >>=?
                fun o -> return (o::a))
             addrs acc)
    rpc_config.listen_addrs []

let init_signal () =
  let handler name id = try
      fatal_error "Received the %s signal, triggering shutdown." name ;
      Lwt_exit.exit id
    with _ -> () in
  ignore (Lwt_unix.on_signal Sys.sigint (handler "INT") : Lwt_unix.signal_handler_id) ;
  ignore (Lwt_unix.on_signal Sys.sigterm (handler "TERM") : Lwt_unix.signal_handler_id)

let run ?verbosity ?sandbox ?checkpoint (config : Node_config_file.t) =
  Node_data_version.ensure_data_dir config.data_dir >>=? fun () ->
  Lwt_lock_file.create
    ~unlink_on_exit:true (Node_data_version.lock_file config.data_dir) >>=? fun () ->
  init_signal () ;
  let log_cfg =
    match verbosity with
    | None -> config.log
    | Some default_level -> { config.log with default_level } in
  Internal_event_unix.init ~lwt_log_sink:log_cfg
    ~configuration:config.internal_events () >>= fun () ->
  Updater.init (Node_data_version.protocol_dir config.data_dir) ;
  lwt_log_notice "Starting the Tezos node..." >>= fun () ->
  begin init_node ?sandbox ?checkpoint config >>= function
    | Ok node -> return node
    | Error (State.Incorrect_history_mode_switch { previous_mode ; next_mode } :: _) ->
        failwith "@[Cannot switch from history mode '%a' to \
                  '%a'. Import a context from a corresponding snapshot \
                  or re-synchronize a node with an empty tezos node \
                  directory.@]"
          History_mode.pp previous_mode
          History_mode.pp next_mode
    | Error _ as err -> Lwt.return err
  end >>=? fun node ->
  init_rpc config.rpc node >>=? fun rpc ->
  lwt_log_notice "The Tezos node is now running!" >>= fun () ->
  Lwt_exit.termination_thread >>= fun x ->
  lwt_log_notice "Shutting down the Tezos node..." >>= fun () ->
  Node.shutdown node >>= fun () ->
  lwt_log_notice "Shutting down the RPC server..." >>= fun () ->
  Lwt_list.iter_p RPC_server.shutdown rpc >>= fun () ->
  lwt_log_notice "BYE (%d)" x >>= fun () ->
  Internal_event_unix.close () >>= fun () ->
  return_unit

let process sandbox verbosity checkpoint args =
  let verbosity =
    let open Internal_event in
    match verbosity with
    | [] -> None
    | [_] -> Some Info
    | _ -> Some Debug in
  let run =
    Node_shared_arg.read_and_patch_config_file
      ~ignore_bootstrap_peers:(match sandbox with
          | Some _ -> true
          | None -> false)
      args >>=? fun config ->
    begin match sandbox with
      | Some _ ->
          if config.data_dir = Node_config_file.default_data_dir
          then failwith "Cannot use default data directory while in sandbox mode"
          else return_unit
      | None -> return_unit
    end >>=? fun () ->
    begin
      match checkpoint with
      | None -> return_none
      | Some s ->
          match Block_header.of_b58check s with
          | Some b -> return_some b
          | None ->
              failwith "Failed to parse the provided checkpoint (Base58Check-encoded)."
    end >>=? fun checkpoint ->
    Lwt_lock_file.is_locked
      (Node_data_version.lock_file config.data_dir) >>=? function
    | false ->
        Lwt.catch
          (fun () -> run ?sandbox ?verbosity ?checkpoint config)
          (function
            |Unix.Unix_error(Unix.EADDRINUSE, "bind","") ->
                Lwt_list.fold_right_s
                  (fun addr acc ->
                     Node_config_file.resolve_rpc_listening_addrs addr >>=
                     fun x -> Lwt.return (x @ acc))
                  config.rpc.listen_addrs [] >>= fun addrlist ->
                fail (RPC_Port_already_in_use addrlist)
            | exn -> Lwt.return (error_exn exn)
          )
    | true -> failwith "Data directory is locked by another process" in
  match Lwt_main.run run with
  | Ok () -> `Ok ()
  | Error err -> `Error (false, Format.asprintf "%a" pp_print_error err)

module Term = struct

  let verbosity =
    let open Cmdliner in
    let doc =
      "Increase log level. Using $(b,-v) is equivalent to \
       using $(b,TEZOS_LOG='* -> info'), and $(b,-vv) is equivalent to using \
       $(b,TEZOS_LOG='* -> debug')." in
    Arg.(value & flag_all &
         info ~docs:Node_shared_arg.Manpage.misc_section ~doc ["v"])

  let sandbox =
    let open Cmdliner in
    let doc =
      "Run the daemon in sandbox mode. \
       P2P to non-localhost addresses are disabled, and constants of \
       the economic protocol can be altered with an optional JSON file. \
       $(b,IMPORTANT): Using sandbox mode affects the node state and \
       subsequent runs of Tezos node must also use sandbox mode. \
       In order to run the node in normal mode afterwards, a full reset \
       must be performed (by removing the node's data directory)."
    in
    Arg.(value & opt ~vopt:(Some None) (some (some string)) None &
         info ~docs:Node_shared_arg.Manpage.misc_section
           ~doc ~docv:"FILE.json" ["sandbox"])

  let checkpoint =
    let open Cmdliner in
    let doc =
      "When asked to take a block hash as a checkpoint, the daemon \
       will only accept the chains that contains that block and those \
       that might reach it."
    in
    Arg.(value & opt (some string) None &
         info ~docs:Node_shared_arg.Manpage.misc_section
           ~doc ~docv:"<level>,<block_hash>" ["checkpoint"])

  let term =
    Cmdliner.Term.(ret (const process $ sandbox $ verbosity $ checkpoint $
                        Node_shared_arg.Term.args))

end

module Manpage = struct

  let command_description =
    "The $(b,run) command is meant to run the Tezos node. \
     Most of its command line arguments corresponds to config file \
     entries, and will have priority over the latter if used."

  let description = [
    `S "DESCRIPTION" ;
    `P command_description ;
  ]

  let debug =
    let log_sections =
      String.concat " "
        (List.rev !Internal_event.Legacy_logging.sections) in
    [
      `S "DEBUG" ;
      `P ("The environment variable $(b,TEZOS_LOG) is used to fine-tune \
           what is going to be logged. The syntax is \
           $(b,TEZOS_LOG='<section> -> <level> [ ; ...]') \
           where section is one of $(i,"
          ^ log_sections ^
          ") and level is one of $(i,fatal), $(i,error), $(i,warn), \
           $(i,notice), $(i,info) or $(i,debug). \
           A $(b,*) can be used as a wildcard \
           in sections, i.e. $(b, client* -> debug). \
           The rules are matched left to right, \
           therefore the leftmost rule is highest priority ."
         ) ;
    ]

  let examples =
    [
      `S "EXAMPLES" ;
      `I ("$(b,Run in sandbox mode listening to RPC commands \
           at localhost port 8732)",
          "$(mname) run --sandbox --data-dir /custom/data/dir \
           --rpc-addr localhost:8732" ) ;
      `I ("$(b,Run a node that accepts network connections)",
          "$(mname) run" ) ;
    ]

  let man =
    description @
    Node_shared_arg.Manpage.args @
    debug @
    examples @
    Node_shared_arg.Manpage.bugs

  let info =
    Cmdliner.Term.info
      ~doc:"Run the Tezos node"
      ~man
      "run"

end

let cmd = Term.term, Manpage.info
