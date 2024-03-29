(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Protocol_client_context
open Protocol
open Alpha_context

type error += Contract_has_no_script of Contract.t
type error += Not_a_supported_multisig_contract of Script.expr
type error += Contract_has_no_storage of Contract.t
type error += Contract_has_unexpected_storage of Contract.t
type error += Invalid_signature of signature
type error += Not_enough_signatures of int * int
type error += Action_deserialisation_error of Script.expr
type error += Bytes_deserialisation_error of MBytes.t
type error += Bad_deserialized_contract of (Contract.t * Contract.t)
type error += Bad_deserialized_counter of (counter * counter)
type error += Non_positive_threshold of int
type error += Threshold_too_high of int * int


let () =
  register_error_kind
    `Permanent
    ~id:"contractHasNoScript"
    ~title: "The given contract is not a multisig contract because it \
             has no script"
    ~description:
      "A multisig command has referenced a scriptless smart contract \
       instead of a multisig smart contract."
    ~pp:(fun ppf contract ->
        Format.fprintf ppf "Contract has no script %a."
          Contract.pp contract)
    Data_encoding.(obj1
                     (req "contract"
                        Contract.encoding))
    (function Contract_has_no_script c -> Some c | _ -> None)
    (fun c -> Contract_has_no_script c);
  register_error_kind
    `Permanent
    ~id:"notASupportedMultisigContract"
    ~title: "The given contract is not one of the supported contracts"
    ~description:
      "A multisig command has referenced a smart contract whose script is \
       not one of the known multisig contract scripts."
    ~pp:(fun ppf script ->
        Format.fprintf ppf "Not a supported multisig contract %a."
          Michelson_v1_printer.print_expr script)
    Data_encoding.(obj1
                     (req "script"
                        Script.expr_encoding))
    (function Not_a_supported_multisig_contract c -> Some c | _ -> None)
    (fun c -> Not_a_supported_multisig_contract c);
  register_error_kind
    `Permanent
    ~id:"contractHasNoStorage"
    ~title: "The given contract is not a multisig contract because it \
             has no storage"
    ~description:
      "A multisig command has referenced a smart contract without \
       storage instead of a multisig smart contract."
    ~pp:(fun ppf contract ->
        Format.fprintf ppf "Contract has no storage %a."
          Contract.pp contract)
    Data_encoding.(obj1
                     (req "contract"
                        Contract.encoding))
    (function Contract_has_no_storage c -> Some c | _ -> None)
    (fun c -> Contract_has_no_storage c);
  register_error_kind
    `Permanent
    ~id:"contractHasUnexpectedStorage"
    ~title: "The storage of the given contract is not of the shape \
             expected for a multisig contract"
    ~description:
      "A multisig command has referenced a smart contract whose \
       storage is of a different shape than the expected one."
    ~pp:(fun ppf contract ->
        Format.fprintf ppf "Contract has unexpected storage %a."
          Contract.pp contract)
    Data_encoding.(obj1
                     (req "contract"
                        Contract.encoding))
    (function Contract_has_unexpected_storage c -> Some c | _ -> None)
    (fun c -> Contract_has_unexpected_storage c);
  register_error_kind
    `Permanent
    ~id:"invalidSignature"
    ~title: "The following signature did not match a public key in the \
             given multisig contract"
    ~description:
      "A signature was given for a multisig contract that matched none \
       of the public keys of the contract signers"
    ~pp:(fun ppf s ->
        Format.fprintf ppf "Invalid signature %s." (Signature.to_b58check s))
    Data_encoding.(obj1 (req "invalid_signature" Signature.encoding))
    (function Invalid_signature s -> Some s | _ -> None)
    (fun s -> Invalid_signature s);
  register_error_kind
    `Permanent
    ~id:"notEnoughSignatures"
    ~title: "Not enough signatures were provided for this multisig action"
    ~description:
      "To run an action on a multisig contract, you should provide at \
       least as many signatures as indicated by the threshold stored \
       in the multisig contract."
    ~pp:(fun ppf (threshold, nsigs) ->
        Format.fprintf ppf "Not enough signatures: only %d signatures \
                            were given but the threshold is currently \
                            %d" nsigs threshold)
    Data_encoding.(obj1 (req "threshold_nsigs" (tup2 int31 int31)))
    (function Not_enough_signatures (threshold, nsigs) -> Some (threshold, nsigs)
            | _ -> None)
    (fun (threshold, nsigs) -> Not_enough_signatures (threshold, nsigs));
  register_error_kind
    `Permanent
    ~id:"actionDeserialisation"
    ~title: "The expression is not a valid multisig action"
    ~description:
      "When trying to deserialise an action from a sequence of bytes, \
       we got an expression that does not correspond to a known \
       multisig action"
    ~pp:(fun ppf e ->
        Format.fprintf ppf "Action deserialisation error %a."
          Michelson_v1_printer.print_expr e)
    Data_encoding.(obj1 (req "expr" Script.expr_encoding))
    (function Action_deserialisation_error e -> Some e | _ -> None)
    (fun e -> Action_deserialisation_error e);
  register_error_kind
    `Permanent
    ~id:"bytesDeserialisation"
    ~title: "The byte sequence is not a valid multisig action"
    ~description:
      "When trying to deserialise an action from a sequence of bytes, \
       we got an error"
    ~pp:(fun ppf b ->
        Format.fprintf ppf "Bytes deserialisation error %s."
          (MBytes.to_string b))
    Data_encoding.(obj1 (req "expr" bytes))
    (function Bytes_deserialisation_error b -> Some b | _ -> None)
    (fun b -> Bytes_deserialisation_error b);
  register_error_kind
    `Permanent
    ~id:"badDeserializedContract"
    ~title: "The byte sequence is not for the given multisig contract"
    ~description:
      "When trying to deserialise an action from a sequence of bytes, \
       we got an action for another multisig contract"
    ~pp:(fun ppf (recieved, expected) ->
        Format.fprintf ppf "Bad deserialized contract, recieved %a expected %a."
          Contract.pp recieved Contract.pp expected)
    Data_encoding.(obj1
                     (req "recieved_expected"
                        (tup2 Contract.encoding Contract.encoding)))
    (function Bad_deserialized_contract b -> Some b | _ -> None)
    (fun b -> Bad_deserialized_contract b);
  register_error_kind
    `Permanent
    ~id:"Bad deserialized counter"
    ~title: "Deserialized counter does not match the stored one"
    ~description:
      "The byte sequence references a multisig counter that does not \
       match the one currently stored in the given multisig contract"
    ~pp:(fun ppf (recieved, expected) ->
        Format.fprintf ppf "Bad deserialized counter, recieved %d expected %d."
          recieved expected)
    Data_encoding.(obj1
                     (req "recieved_expected"
                        (tup2 int31 int31)))
    (function Bad_deserialized_counter (c1, c2) -> Some (Z.to_int c1, Z.to_int c2)
            | _ -> None)
    (fun (c1, c2) -> Bad_deserialized_counter (Z.of_int c1, Z.of_int c2));
  register_error_kind
    `Permanent
    ~id:"thresholdTooHigh"
    ~title: "Given threshold is too high"
    ~description:
      "The given threshold is higher than the number of keys, this \
       would lead to a frozen multisig contract"
    ~pp:(fun ppf (threshold, nkeys) ->
        Format.fprintf ppf "Threshold too high: %d expected at most %d."
          threshold nkeys)
    Data_encoding.(obj1
                     (req "recieved_expected"
                        (tup2 int31 int31)))
    (function Threshold_too_high (c1, c2) -> Some (c1, c2)
            | _ -> None)
    (fun (c1, c2) -> Threshold_too_high (c1, c2));
  register_error_kind
    `Permanent
    ~id:"nonPositiveThreshold"
    ~title: "Given threshold is not positive"
    ~description:
      "A multisig threshold should be a positive number"
    ~pp:(fun ppf threshold ->
        Format.fprintf ppf "Multisig threshold %d should be positive."
          threshold)
    Data_encoding.(obj1
                     (req "threshold" int31))
    (function Non_positive_threshold t -> Some t | _ -> None)
    (fun t -> Non_positive_threshold t)


(* The multisig contract script written by Arthur Breitman
     https://github.com/murbard/smart-contracts/blob/master/multisig/michelson/multisig.tz *)
let multisig_script_string =
  "parameter (pair
             (pair :payload
                (nat %counter) # counter, used to prevent replay attacks
                (or :action    # payload to sign, represents the requested action
                   (pair :transfer    # transfer tokens
                      (mutez %amount) # amount to transfer
                      (contract %dest unit)) # destination to transfer to
                   (or
                      (option %delegate key_hash) # change the delegate to this address
                      (pair %change_keys          # change the keys controlling the multisig
                         (nat %threshold)         # new threshold
                         (list %keys key)))))     # new list of keys
             (list %sigs (option signature)));    # signatures

storage (pair (nat %stored_counter) (pair (nat %threshold) (list %keys key))) ;

code
  {
    UNPAIR ; SWAP ; DUP ; DIP { SWAP } ;
    DIP
      {
        UNPAIR ;
        # pair the payload with the current contract address, to ensure signatures
        # can't be replayed accross different contracts if a key is reused.
        DUP ; SELF ; ADDRESS ; PAIR ;
        PACK ; # form the binary payload that we expect to be signed
        DIP { UNPAIR @counter ; DIP { SWAP } } ; SWAP
      } ;

    # Check that the counters match
    UNPAIR @stored_counter; DIP { SWAP };
    ASSERT_CMPEQ ;

    # Compute the number of valid signatures
    DIP { SWAP } ; UNPAIR @threshold @keys;
    DIP
      {
        # Running count of valid signatures
        PUSH @valid nat 0; SWAP ;
        ITER
          {
            DIP { SWAP } ; SWAP ;
            IF_CONS
              {
                IF_SOME
                  { SWAP ;
                    DIP
                      {
                        SWAP ; DIIP { DUUP } ;
                        # Checks signatures, fails if invalid
                        { DUUUP; DIP {CHECK_SIGNATURE}; SWAP; IF {DROP} {FAILWITH} };
                        PUSH nat 1 ; ADD @valid } }
                  { SWAP ; DROP }
              }
              {
                # There were fewer signatures in the list
                # than keys. Not all signatures must be present, but
                # they should be marked as absent using the option type.
                FAIL
              } ;
            SWAP
          }
      } ;
    # Assert that the threshold is less than or equal to the
    # number of valid signatures.
    ASSERT_CMPLE ;
    DROP ; DROP ;

    # Increment counter and place in storage
    DIP { UNPAIR ; PUSH nat 1 ; ADD @new_counter ; PAIR} ;

    # We have now handled the signature verification part,
    # produce the operation requested by the signers.
    NIL operation ; SWAP ;
    IF_LEFT
      { # Transfer tokens
        UNPAIR ; UNIT ; TRANSFER_TOKENS ; CONS }
      { IF_LEFT {
                  # Change delegate
                  SET_DELEGATE ; CONS }
                {
                  # Change set of signatures
                  DIP { SWAP ; CAR } ; SWAP ; PAIR ; SWAP }} ;
    PAIR }
"

(* Client_proto_context.originate expects the contract script as a Script.expr *)
let multisig_script : Script.expr tzresult =
  Tezos_micheline.Micheline_parser.no_parsing_error
  @@ Michelson_v1_parser.parse_toplevel ?check:(Some true)
    multisig_script_string >>? fun parsing_result  ->
  ok parsing_result.Michelson_v1_parser.expanded

let multisig_script_hash =
  multisig_script >>? fun mcontract ->
  let bytes = Data_encoding.Binary.to_bytes_exn Script.expr_encoding mcontract in
  let hash = Script_expr_hash.hash_bytes [ bytes ] in
  ok hash

let known_multisig_hashes =
  multisig_script_hash >>? fun hash -> ok ([hash])

let check_multisig_script script : unit tzresult Lwt.t =
  let bytes = Data_encoding.force_bytes script in
  let hash = Script_expr_hash.hash_bytes [ bytes ] in
  Lwt.return known_multisig_hashes >>=? fun l ->
  fold_left_s (fun b h -> return (b || (Script_expr_hash.(h = hash))))
    false l >>=? fun hash_found ->
  fail_unless hash_found (Not_a_supported_multisig_contract
                            (match Data_encoding.force_decode script with
                             | Some s -> s
                             | None -> assert false))

(* Returns [Ok ()] if [~contract] is an originated contract whose code
   is [multisig_script] *)
let check_multisig_contract (cctxt : #Protocol_client_context.full) ~chain ~block contract =
  Client_proto_context.get_script cctxt ~chain ~block contract >>=? fun script_opt ->
  (match script_opt with
   | Some script -> return script.code
   | None -> fail (Contract_has_no_script contract))
  >>=? check_multisig_script

let seq ~loc l = Tezos_micheline.Micheline.Seq (loc, l)
let pair ~loc a b = Tezos_micheline.Micheline.Prim (loc, Script.D_Pair, [a; b], [])
let none ~loc () = Tezos_micheline.Micheline.Prim (loc, Script.D_None, [], [])
let some ~loc a = Tezos_micheline.Micheline.Prim (loc, Script.D_Some, [a], [])
let left ~loc a = Tezos_micheline.Micheline.Prim (loc, Script.D_Left, [a], [])
let right ~loc b = Tezos_micheline.Micheline.Prim (loc, Script.D_Right, [b], [])
let int ~loc i = Tezos_micheline.Micheline.Int (loc, i)
let bytes ~loc s = Tezos_micheline.Micheline.Bytes (loc, s)

(** * Actions *)

type multisig_action =
  | Transfer of Tez.t * Contract.t
  | Change_delegate of public_key_hash option
  | Change_keys of Z.t * public_key list

let action_to_expr ~loc = function
  | Transfer (amount, destination) ->
      left ~loc (pair ~loc
                   (int ~loc (Z.of_int64 (Tez.to_mutez amount)))
                   (bytes ~loc
                      (Data_encoding.Binary.to_bytes_exn
                         Contract.encoding destination)))
  | Change_delegate delegate_opt ->
      right ~loc (left ~loc
                    (match delegate_opt with
                     | None -> none ~loc ()
                     | Some delegate ->
                         some ~loc
                           (bytes ~loc
                              (Data_encoding.Binary.to_bytes_exn
                                 Signature.Public_key_hash.encoding delegate))))
  | Change_keys (threshold, keys) ->
      right ~loc (right ~loc
                    (pair ~loc
                       (int ~loc threshold)
                       (seq ~loc (List.map
                                    (fun k ->
                                       bytes ~loc
                                         (Data_encoding.Binary.to_bytes_exn
                                            Signature.Public_key.encoding k))
                                    keys))))

let action_of_expr e =
  let fail () =
    Error_monad.fail
      (Action_deserialisation_error (Tezos_micheline.Micheline.strip_locations e))
  in
  match e with
  | Tezos_micheline.Micheline.Prim (_, Script.D_Left, [
      Tezos_micheline.Micheline.Prim (_, Script.D_Pair, [
          Tezos_micheline.Micheline.Int (_, i);
          Tezos_micheline.Micheline.Bytes (_, s)], [])], []) ->
      begin match Tez.of_mutez (Z.to_int64 i) with
        | None -> fail ()
        | Some amount ->
            return @@
            Transfer (amount,
                      Data_encoding.Binary.of_bytes_exn
                        Contract.encoding s)
      end
  | Tezos_micheline.Micheline.Prim (_, Script.D_Right, [
      Tezos_micheline.Micheline.Prim (_, Script.D_Left, [
          Tezos_micheline.Micheline.Prim (_, Script.D_None, [], [])], [])], []) ->
      return @@
      Change_delegate None
  | Tezos_micheline.Micheline.Prim (_, Script.D_Right, [
      Tezos_micheline.Micheline.Prim (_, Script.D_Left, [
          Tezos_micheline.Micheline.Prim (_, Script.D_Some, [
              Tezos_micheline.Micheline.Bytes (_, s)], [])], [])], []) ->
      return @@
      Change_delegate (Some (Data_encoding.Binary.of_bytes_exn
                               Signature.Public_key_hash.encoding s))
  | Tezos_micheline.Micheline.Prim (_, Script.D_Right, [
      Tezos_micheline.Micheline.Prim (_, Script.D_Right, [
          Tezos_micheline.Micheline.Prim (_, Script.D_Pair, [
              Tezos_micheline.Micheline.Int (_, threshold);
              Tezos_micheline.Micheline.Seq (_, key_bytes)], [])], [])], []) ->
      map_s (function
          | Tezos_micheline.Micheline.Bytes (_, s) ->
              return @@
              Data_encoding.Binary.of_bytes_exn
                Signature.Public_key.encoding s
          | _ -> fail ())
        key_bytes >>=? fun keys ->
      return @@
      Change_keys (threshold, keys)
  | _ -> fail ()

type key_list = Signature.Public_key.t list

(* The relevant information that we can get about a multisig smart contract *)
type multisig_contract_information =
  {
    counter : Z.t;
    threshold : Z.t;
    keys : key_list;
  }

let multisig_get_information (cctxt : #Protocol_client_context.full) ~chain ~block contract =
  let open Client_proto_context in
  let open Tezos_micheline.Micheline in
  get_storage cctxt ~chain ~block contract >>=? fun storage_opt ->
  match storage_opt with
  | None -> fail (Contract_has_no_storage contract)
  | Some storage ->
      begin match root storage with
        | Prim (_, D_Pair, [Int (_, counter);
                            Prim (_, D_Pair, [Int (_, threshold);
                                              Seq (_, key_nodes)], _)], _) ->
            map_s (function
                | String (_, key_str) ->
                    return @@ Signature.Public_key.of_b58check_exn key_str
                | _ -> fail (Contract_has_unexpected_storage contract)
              ) key_nodes >>=? fun keys ->
            return { counter; threshold; keys }
        | _ -> fail (Contract_has_unexpected_storage contract)
      end

let multisig_create_storage ~counter ~threshold ~keys () : Script.expr tzresult Lwt.t =
  let loc = Tezos_micheline.Micheline_parser.location_zero in
  let open Tezos_micheline.Micheline in
  map_s (fun key ->
      let key_str = Signature.Public_key.to_b58check key in
      return (String (loc, key_str)))
    keys >>=? fun l ->
  return @@ strip_locations @@
  pair ~loc (int ~loc counter) (pair ~loc (int ~loc threshold) (seq ~loc l))

(* Client_proto_context.originate expects the initial storage as a string *)
let multisig_storage_string ~counter ~threshold ~keys () =
  multisig_create_storage ~counter ~threshold ~keys () >>=? fun expr ->
  return @@
  Format.asprintf "%a" Michelson_v1_printer.print_expr expr

let multisig_create_param ~counter ~action ~optional_signatures () : Script.expr tzresult Lwt.t =
  let loc = Tezos_micheline.Micheline_parser.location_zero in
  let open Tezos_micheline.Micheline in
  map_s (fun sig_opt ->
      match sig_opt with
      | None -> return @@ none ~loc ()
      | Some signature ->
          return @@
          some ~loc (String (loc, Signature.to_b58check signature))
    ) optional_signatures >>=? fun l ->
  return @@ strip_locations @@
  pair ~loc
    (pair ~loc (int ~loc counter)
       (action_to_expr ~loc action))
    (Seq (loc, l))

let mutlisig_param_string ~counter ~action ~optional_signatures () =
  multisig_create_param ~counter ~action ~optional_signatures () >>=? fun expr ->
  return @@
  Format.asprintf "%a" Michelson_v1_printer.print_expr expr

let multisig_bytes ~counter ~action ~contract () =
  let loc = Tezos_micheline.Micheline_parser.location_zero in
  let triple =
    pair ~loc
      (bytes ~loc (Data_encoding.Binary.to_bytes_exn Contract.encoding contract))
      (pair ~loc (int ~loc counter)
         (action_to_expr ~loc action))
  in
  let bytes =
    Data_encoding.Binary.to_bytes_exn Script.expr_encoding @@
    Tezos_micheline.Micheline.strip_locations @@
    triple
  in
  return @@ MBytes.concat "" [ MBytes.of_string "\005" ; bytes ]

let check_threshold ~threshold ~keys () =
  let nkeys = List.length keys in
  let threshold = Z.to_int threshold in
  if Compare.Int.(List.length keys < threshold) then
    fail (Threshold_too_high (threshold, nkeys))
  else
  if Compare.Int.(threshold <= 0) then
    fail (Non_positive_threshold threshold)
  else
    return_unit

let originate_multisig
    (cctxt : #Protocol_client_context.full)
    ~chain ~block ?confirmations
    ?dry_run
    ?branch
    ?fee
    ?gas_limit
    ?storage_limit
    ~delegate
    ?(delegatable=false)
    ?(spendable=false)
    ~threshold
    ~keys
    ~manager
    ~balance
    ~source
    ~src_pk
    ~src_sk
    ~fee_parameter
    () =
  Lwt.return multisig_script >>=? fun code ->
  multisig_storage_string ~counter:Z.zero ~threshold ~keys () >>=? fun initial_storage ->
  check_threshold ~threshold ~keys () >>=? fun () ->
  Client_proto_context.originate_contract cctxt
    ~chain ~block ?branch ?confirmations ?dry_run ?fee ?gas_limit ?storage_limit
    ~delegate ~delegatable ~spendable ~initial_storage
    ~manager ~balance ~source ~src_pk ~src_sk ~code ~fee_parameter
    ()

type multisig_prepared_action =
  {
    bytes : MBytes.t;
    threshold : Z.t;
    keys : public_key list;
    counter : Z.t;
  }


let check_action ~action () =
  match action with
  | Change_keys (threshold, keys) ->
      check_threshold ~threshold ~keys ()
  | _ -> return_unit

let prepare_multisig_transaction (cctxt : #Protocol_client_context.full)
    ~chain ~block ~multisig_contract ~action () =
  let contract = multisig_contract in
  check_multisig_contract cctxt ~chain ~block contract >>=? fun () ->
  check_action ~action () >>=? fun () ->
  multisig_get_information cctxt ~chain ~block contract >>=?
  fun {counter; threshold; keys} ->
  multisig_bytes ~counter ~action ~contract () >>=? fun bytes ->
  return {bytes; threshold; keys; counter}

let check_multisig_signatures ~bytes ~threshold ~keys signatures =
  let key_array = Array.of_list keys in
  let nkeys = Array.length key_array in
  let opt_sigs_arr = Array.make nkeys None in
  let matching_key_found = ref false in
  let check_signature_against_key_number signature i key =
    _when (Signature.check key signature bytes)
      (fun () ->
         return @@ (
           matching_key_found := true;
           opt_sigs_arr.(i) <- Some signature))
  in
  iter_p
    (fun signature ->
       return @@ (matching_key_found := false) >>=? fun () ->
       iteri_p (check_signature_against_key_number signature) keys >>=? fun () ->
       fail_unless !matching_key_found (Invalid_signature signature)
    ) signatures >>=? fun () ->
  let opt_sigs = Array.to_list opt_sigs_arr in
  let signature_count =
    List.fold_left
      (fun n sig_opt -> match sig_opt with Some _ -> n + 1 | None -> n)
      0 opt_sigs
  in
  let threshold_int = Z.to_int threshold in
  if (signature_count >= threshold_int) then return opt_sigs else
    fail (Not_enough_signatures (threshold_int, signature_count))

let call_multisig (cctxt : #Protocol_client_context.full)
    ~chain ~block ?confirmations
    ?dry_run
    ?branch ~source ~src_pk ~src_sk ~multisig_contract ~action ~signatures
    ~amount ?fee ?gas_limit ?storage_limit ?counter
    ~fee_parameter
    () =
  prepare_multisig_transaction cctxt ~chain ~block ~multisig_contract ~action () >>=?
  fun {bytes; threshold; keys; counter=stored_counter} ->
  check_multisig_signatures ~bytes ~threshold ~keys signatures >>=?
  fun optional_signatures ->
  mutlisig_param_string ~counter:stored_counter ~action ~optional_signatures () >>=? fun arg ->
  Client_proto_context.transfer cctxt ~chain ~block ?confirmations
    ?dry_run
    ?branch ~source ~src_pk ~src_sk ~destination:multisig_contract ~arg
    ~amount ?fee ?gas_limit ?storage_limit ?counter
    ~fee_parameter
    ()

let action_of_bytes ~multisig_contract ~stored_counter bytes =
  if Compare.Int.(MBytes.length bytes >= 1) &&
     Compare.Int.(MBytes.get_uint8 bytes 0 = 0x05) then
    let nbytes = MBytes.sub bytes 1 (MBytes.length bytes - 1) in
    match Data_encoding.Binary.of_bytes Script.expr_encoding nbytes with
    | None -> fail (Bytes_deserialisation_error bytes)
    | Some e ->
        begin match Tezos_micheline.Micheline.root e with
          | Tezos_micheline.Micheline.Prim (_, Script.D_Pair, [
              Tezos_micheline.Micheline.Bytes (_, contract_bytes);
              Tezos_micheline.Micheline.Prim (_, Script.D_Pair, [
                  Tezos_micheline.Micheline.Int (_, counter); e], [])], []) ->
              let contract =
                Data_encoding.Binary.of_bytes_exn
                  Contract.encoding contract_bytes
              in
              if (counter = stored_counter) then
                if (multisig_contract = contract) then action_of_expr e
                else fail (Bad_deserialized_contract (contract, multisig_contract))
              else fail (Bad_deserialized_counter (counter, stored_counter))
          | _ -> fail (Bytes_deserialisation_error bytes)
        end
  else
    fail (Bytes_deserialisation_error bytes)

let call_multisig_on_bytes (cctxt : #Protocol_client_context.full)
    ~chain ~block ?confirmations
    ?dry_run
    ?branch ~source ~src_pk ~src_sk ~multisig_contract ~bytes ~signatures
    ~amount ?fee ?gas_limit ?storage_limit ?counter
    ~fee_parameter
    () =
  multisig_get_information cctxt ~chain ~block multisig_contract >>=?
  fun info ->
  action_of_bytes ~multisig_contract ~stored_counter:info.counter bytes >>=? fun action ->
  call_multisig cctxt ~chain ~block ?confirmations ?dry_run
    ?branch ~source ~src_pk ~src_sk ~multisig_contract ~action ~signatures
    ~amount ?fee ?gas_limit ?storage_limit ?counter
    ~fee_parameter
    ()
