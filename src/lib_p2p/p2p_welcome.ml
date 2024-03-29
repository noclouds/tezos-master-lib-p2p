(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

include Internal_event.Legacy_logging.Make (struct let name = "p2p.welcome" end)

type pool = Pool : ('msg, 'meta, 'meta_conn) P2p_pool.t -> pool

type t = {
  socket: Lwt_unix.file_descr ;
  canceler: Lwt_canceler.t ;
  pool: pool ;
  mutable worker: unit Lwt.t ;
}

let rec worker_loop st =
  let Pool pool = st.pool in
  Lwt_unix.yield () >>= fun () ->
  protect ~canceler:st.canceler begin fun () ->
    P2p_fd.accept st.socket >>= return
  end >>= function
  | Ok (fd, addr) ->
      let point =
        match addr with
        | Lwt_unix.ADDR_UNIX _ -> assert false
        | Lwt_unix.ADDR_INET (addr, port) ->
            (Ipaddr_unix.V6.of_inet_addr_exn addr, port) in
      P2p_pool.accept pool fd point ;
      worker_loop st

  (* Unix errors related to the failure to create one connection,
     No reason to abort just now, but we want to stress out that we
     have a problem preventing us from accepting new connections. *)
  | Error (((Exn (Unix.Unix_error ((
      EMFILE              (* Too many open files by the process *)
    | ENFILE              (* Too many open files in the system *)
    | ENETDOWN            (* Network is down *)
    ), _ , _))
    ) :: _) as err) ->
      lwt_log_error "@[<v 2>Incoming connection failed with %a in the
      Welcome worker. Resuming in 5s.@]"
        pp_print_error err >>= fun () ->
      (* These are temporary system errors, giving some time for the system to
         recover *)
      Lwt_unix.sleep 5. >>= fun () ->
      worker_loop st
  | Error (((Exn (Unix.Unix_error ((
      EAGAIN              (* Resource temporarily unavailable; try again *)
    | EWOULDBLOCK         (* Operation would block *)
    | ENOPROTOOPT         (* Protocol not available *)
    | EOPNOTSUPP          (* Operation not supported on socket *)
    | ENETUNREACH         (* Network is unreachable *)
    | ECONNABORTED        (* Software caused connection abort *)
    | ECONNRESET          (* Connection reset by peer *)
    | ETIMEDOUT           (* Connection timed out *)
    | EHOSTDOWN           (* Host is down *)
    | EHOSTUNREACH        (* No route to host *)
    (* Ugly hack to catch EPROTO and ENONET, Protocol error, which are not
       defined in the Unix module (which is 20 years late on the POSIX
       standard). A better solution is to use the package ocaml-unix-errno or
       redo the work *)
    | EUNKNOWNERR (71|64)
    (* On Linux EPROTO is 71, ENONET is 64
       On BSD systems, accept cannot raise EPROTO.
       71 is EREMOTE   for openBSD, NetBSD, Darwin, which is irrelevant here
       64 is EHOSTDOWN for openBSD, NetBSD, Darwin, which is already caught
    *)
    ), _ , _))
    ) :: _) as err) ->
      (* These are socket-specific errors, ignoring. *)
      lwt_log_error "@[<v 2>Incoming connection failed with %a in the Welcome worker@]"
        pp_print_error err >>= fun () ->
      worker_loop st
  | Error (Canceled :: _) ->
      Lwt.return_unit
  | Error err ->
      lwt_log_error "@[<v 2>Unexpected error in the Welcome worker@ %a@]"
        pp_print_error err

let create_listening_socket ~backlog ?(addr = Ipaddr.V6.unspecified) port =
  let main_socket = Lwt_unix.(socket PF_INET6 SOCK_STREAM 0) in
  Lwt_unix.(setsockopt main_socket SO_REUSEADDR true) ;
  Lwt_unix.bind main_socket
    Unix.(ADDR_INET (Ipaddr_unix.V6.to_inet_addr addr, port)) >>= fun () ->
  Lwt_unix.listen main_socket backlog ;
  Lwt.return main_socket

let create ?addr ~backlog pool port =
  Lwt.catch begin fun () ->
    create_listening_socket
      ~backlog ?addr port >>= fun socket ->
    let canceler = Lwt_canceler.create () in
    Lwt_canceler.on_cancel canceler begin fun () ->
      Lwt_utils_unix.safe_close socket
    end ;
    let st = {
      socket ; canceler ; pool = Pool pool ;
      worker = Lwt.return_unit ;
    } in
    Lwt.return st
  end begin fun exn ->
    lwt_log_error
      "@[<v 2>Cannot accept incoming connections@ %a@]"
      pp_exn exn >>= fun () ->
    Lwt.fail exn
  end

let activate st =
  st.worker <-
    Lwt_utils.worker "welcome"
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> worker_loop st)
      ~cancel:(fun () -> Lwt_canceler.cancel st.canceler)

let shutdown st =
  Lwt_canceler.cancel st.canceler >>= fun () ->
  st.worker
