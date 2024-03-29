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

include Internal_event.Legacy_logging.Make(struct
    let name = "p2p"
  end)

type 'peer_meta peer_meta_config = 'peer_meta P2p_pool.peer_meta_config = {
  peer_meta_encoding : 'peer_meta Data_encoding.t ;
  peer_meta_initial : unit -> 'peer_meta ;
  score : 'peer_meta -> float ;
}

type 'conn_meta conn_meta_config = 'conn_meta P2p_socket.metadata_config = {
  conn_meta_encoding : 'conn_meta Data_encoding.t ;
  conn_meta_value : P2p_peer.Id.t -> 'conn_meta ;
  private_node : 'conn_meta -> bool ;
}

type 'msg app_message_encoding = 'msg P2p_message.encoding =
    Encoding : {
      tag: int ;
      title: string ;
      encoding: 'a Data_encoding.t ;
      wrap: 'a -> 'msg ;
      unwrap: 'msg -> 'a option ;
      max_length: int option ;
    } -> 'msg app_message_encoding

type 'msg message_config = 'msg P2p_pool.message_config = {
  encoding : 'msg app_message_encoding list ;
  chain_name : Distributed_db_version.name ;
  distributed_db_versions : Distributed_db_version.t list ;
}

type config = {
  listening_port : P2p_addr.port option ;
  listening_addr : P2p_addr.t option ;
  discovery_port : P2p_addr.port option ;
  discovery_addr : Ipaddr.V4.t option ;
  trusted_points : P2p_point.Id.t list ;
  peers_file : string ;
  private_mode : bool ;
  identity : P2p_identity.t ;
  proof_of_work_target : Crypto_box.target ;
  disable_mempool : bool ;
  trust_discovered_peers : bool ;
  disable_testchain : bool ;
  greylisting_config : P2p_point_state.Info.greylisting_config ;
}

type limits = {

  connection_timeout : Time.System.Span.t ;
  authentication_timeout : Time.System.Span.t ;
  greylist_timeout : Time.System.Span.t ;
  maintenance_idle_time : Time.System.Span.t ;

  min_connections : int ;
  expected_connections : int ;
  max_connections : int ;

  backlog : int ;
  max_incoming_connections : int ;

  max_download_speed : int option ;
  max_upload_speed : int option ;

  read_buffer_size : int ;
  read_queue_size : int option ;
  write_queue_size : int option ;
  incoming_app_message_queue_size : int option ;
  incoming_message_queue_size : int option ;
  outgoing_message_queue_size : int option ;

  known_peer_ids_history_size : int ;
  known_points_history_size : int ;
  max_known_peer_ids : (int * int) option ;
  max_known_points : (int * int) option ;

  swap_linger : Time.System.Span.t ;

  binary_chunks_size : int option ;
}

let create_scheduler limits =
  let max_upload_speed =
    Option.map limits.max_upload_speed ~f:(( * ) 1024) in
  let max_download_speed =
    Option.map limits.max_upload_speed ~f:(( * ) 1024) in
  P2p_io_scheduler.create
    ~read_buffer_size:limits.read_buffer_size
    ?max_upload_speed
    ?max_download_speed
    ?read_queue_size:limits.read_queue_size
    ?write_queue_size:limits.write_queue_size
    ()

let create_connection_pool config limits meta_cfg conn_meta_cfg msg_cfg io_sched =
  let pool_cfg = {
    P2p_pool.identity = config.identity ;
    proof_of_work_target = config.proof_of_work_target ;
    listening_port = config.listening_port ;
    trusted_points = config.trusted_points ;
    peers_file = config.peers_file ;
    private_mode = config.private_mode ;
    greylisting_config = config.greylisting_config ;
    min_connections = limits.min_connections ;
    max_connections = limits.max_connections ;
    max_incoming_connections = limits.max_incoming_connections ;
    connection_timeout = limits.connection_timeout ;
    authentication_timeout = limits.authentication_timeout ;
    incoming_app_message_queue_size = limits.incoming_app_message_queue_size ;
    incoming_message_queue_size = limits.incoming_message_queue_size ;
    outgoing_message_queue_size = limits.outgoing_message_queue_size ;
    known_peer_ids_history_size = limits.known_peer_ids_history_size ;
    known_points_history_size = limits.known_points_history_size ;
    max_known_points = limits.max_known_points ;
    max_known_peer_ids = limits.max_known_peer_ids ;
    swap_linger = limits.swap_linger ;
    binary_chunks_size = limits.binary_chunks_size ;
  }
  in
  let pool =
    P2p_pool.create pool_cfg meta_cfg conn_meta_cfg msg_cfg io_sched in
  pool

let may_create_discovery_worker _limits config pool =
  match (config.listening_port, config.discovery_port, config.discovery_addr) with
  | (Some listening_port, Some discovery_port, Some discovery_addr) ->
      Some (P2p_discovery.create pool
              config.identity.peer_id
              ~listening_port
              ~discovery_port ~discovery_addr
              ~trust_discovered_peers:config.trust_discovered_peers)
  | (_, _, _) ->
      None

let bounds ~min ~expected ~max =
  assert (min <= expected) ;
  assert (expected <= max) ;
  let step_min =
    (expected - min) / 3
  and step_max =
    (max - expected) / 3 in
  { P2p_maintenance.min_threshold = min + step_min ;
    min_target = min + 2 * step_min ;
    max_target = max - 2 * step_max ;
    max_threshold = max - step_max ;
  }

let create_maintenance_worker limits pool config =
  let bounds =
    bounds
      ~min:limits.min_connections
      ~expected:limits.expected_connections
      ~max:limits.max_connections in
  let maintenance_config = {
    P2p_maintenance.
    maintenance_idle_time = limits.maintenance_idle_time ;
    greylist_timeout = limits.greylist_timeout ;
    private_mode = config.private_mode ;
  } in
  let discovery = may_create_discovery_worker limits config pool in
  P2p_maintenance.create ?discovery maintenance_config bounds pool

let may_create_welcome_worker config limits pool =
  match config.listening_port with
  | None -> Lwt.return_none
  | Some port ->
      P2p_welcome.create
        ~backlog:limits.backlog pool
        ?addr:config.listening_addr
        port >>= fun w ->
      Lwt.return_some w

type ('msg, 'peer_meta, 'conn_meta) connection =
  ('msg, 'peer_meta, 'conn_meta) P2p_pool.connection

module Real = struct

  type ('msg, 'peer_meta, 'conn_meta) net = {
    config: config ;
    limits: limits ;
    io_sched: P2p_io_scheduler.t ;
    pool: ('msg, 'peer_meta, 'conn_meta) P2p_pool.t ;
    maintenance: 'peer_meta P2p_maintenance.t ;
    welcome: P2p_welcome.t option ;
  }

  let create ~config ~limits meta_cfg conn_meta_cfg msg_cfg =
    let io_sched = create_scheduler limits in
    create_connection_pool
      config limits meta_cfg conn_meta_cfg msg_cfg io_sched >>= fun pool ->
    let maintenance = create_maintenance_worker limits pool config in
    may_create_welcome_worker config limits pool >>= fun welcome ->
    return {
      config ;
      limits ;
      io_sched ;
      pool ;
      maintenance ;
      welcome ;
    }

  let peer_id { config ; _ } = config.identity.peer_id


  let maintain { maintenance ; _ } () =
    P2p_maintenance.maintain maintenance

  let activate t () =
    log_info "activate";
    begin
      match t.welcome with
      | None -> ()
      | Some w -> P2p_welcome.activate w
    end ;
    P2p_maintenance.activate t.maintenance ;
    Lwt.async (fun () -> P2p_maintenance.maintain t.maintenance) ;
    ()

  let roll _net () = Lwt.return_unit (* TODO implement *)

  (* returns when all workers have shutted down in the opposite
     creation order. *)
  let shutdown net () =
    lwt_log_notice "Shutting down the p2p's welcome worker..." >>= fun () ->
    Lwt_utils.may ~f:P2p_welcome.shutdown net.welcome >>= fun () ->
    lwt_log_notice "Shutting down the p2p's network maintenance worker..." >>= fun () ->
    P2p_maintenance.shutdown net.maintenance >>= fun () ->
    lwt_log_notice "Shutting down the p2p connection pool..." >>= fun () ->
    P2p_pool.destroy net.pool >>= fun () ->
    lwt_log_notice "Shutting down the p2p scheduler..." >>= fun () ->
    P2p_io_scheduler.shutdown ~timeout:3.0 net.io_sched

  let connections { pool ; _ } () =
    P2p_pool.Connection.fold pool
      ~init:[] ~f:(fun _peer_id c acc -> c :: acc)
  let find_connection { pool ; _ } peer_id =
    P2p_pool.Connection.find_by_peer_id pool peer_id
  let disconnect ?wait conn =
    P2p_pool.disconnect ?wait conn
  let connection_info _net conn =
    P2p_pool.Connection.info conn
  let connection_local_metadata _net conn =
    P2p_pool.Connection.local_metadata conn
  let connection_remote_metadata _net conn =
    P2p_pool.Connection.remote_metadata conn
  let connection_stat _net conn =
    P2p_pool.Connection.stat conn
  let global_stat { pool ; _ } () =
    P2p_pool.pool_stat pool
  let set_peer_metadata { pool ; _ } conn meta =
    P2p_pool.Peers.set_peer_metadata pool conn meta
  let get_peer_metadata { pool ; _ } conn =
    P2p_pool.Peers.get_peer_metadata pool conn

  let recv _net conn =
    P2p_pool.read conn >>=? fun msg ->
    lwt_debug "message read from %a"
      P2p_peer.Id.pp
      (P2p_pool.Connection.info conn).peer_id >>= fun () ->
    return msg

  let rec recv_any net () =
    let pipes =
      P2p_pool.Connection.fold
        net.pool ~init:[]
        ~f:begin fun _peer_id conn acc ->
          (P2p_pool.is_readable conn >>= function
            | Ok () -> Lwt.return_some conn
            | Error _ -> Lwt_utils.never_ending ()) :: acc
        end in
    Lwt.pick (
      ( P2p_pool.Pool_event.wait_new_connection net.pool >>= fun () ->
        Lwt.return_none )::
      pipes) >>= function
    | None -> recv_any net ()
    | Some conn ->
        P2p_pool.read conn >>= function
        | Ok msg ->
            lwt_debug "message read from %a"
              P2p_peer.Id.pp
              (P2p_pool.Connection.info conn).peer_id >>= fun () ->
            Lwt.return (conn, msg)
        | Error _ ->
            lwt_debug "error reading message from %a"
              P2p_peer.Id.pp
              (P2p_pool.Connection.info conn).peer_id >>= fun () ->
            Lwt_unix.yield () >>= fun () ->
            recv_any net ()

  let send _net conn m =
    P2p_pool.write conn m >>= function
    | Ok () ->
        lwt_debug "message sent to %a"
          P2p_peer.Id.pp
          (P2p_pool.Connection.info conn).peer_id >>= fun () ->
        return_unit
    | Error err ->
        lwt_debug "error sending message from %a: %a"
          P2p_peer.Id.pp
          (P2p_pool.Connection.info conn).peer_id
          pp_print_error err >>= fun () ->
        Lwt.return_error err

  let try_send _net conn v =
    match P2p_pool.write_now conn v with
    | Ok v ->
        debug "message trysent to %a"
          P2p_peer.Id.pp
          (P2p_pool.Connection.info conn).peer_id ;
        v
    | Error err ->
        debug "error trysending message to %a@ %a"
          P2p_peer.Id.pp
          (P2p_pool.Connection.info conn).peer_id
          pp_print_error err ;
        false

  let broadcast { pool ; _ } msg =
    P2p_pool.write_all pool msg ;
    debug "message broadcasted"

  let fold_connections { pool ; _ } ~init ~f =
    P2p_pool.Connection.fold pool ~init ~f

  let iter_connections { pool ; _ } f =
    P2p_pool.Connection.fold pool
      ~init:()
      ~f:(fun gid conn () -> f gid conn)

  let on_new_connection { pool ; _ } f =
    P2p_pool.on_new_connection pool f

end

module Fake = struct

  let id = P2p_identity.generate (Crypto_box.make_target 0.)
  let empty_stat = {
    P2p_stat.total_sent = 0L ;
    total_recv = 0L ;
    current_inflow = 0 ;
    current_outflow = 0 ;
  }
  let connection_info announced_version faked_metadata = {
    P2p_connection.Info.incoming = false ;
    peer_id = id.peer_id ;
    id_point = (Ipaddr.V6.unspecified, None) ;
    remote_socket_port = 0 ;
    announced_version ;
    local_metadata = faked_metadata ;
    remote_metadata = faked_metadata ;
    private_node = false ;
  }

end

type ('msg, 'peer_meta, 'conn_meta) t = {
  announced_version : Network_version.t ;
  peer_id : P2p_peer.Id.t ;
  maintain : unit -> unit Lwt.t ;
  roll : unit -> unit Lwt.t ;
  shutdown : unit -> unit Lwt.t ;
  connections : unit -> ('msg, 'peer_meta, 'conn_meta) connection list ;
  find_connection :
    P2p_peer.Id.t -> ('msg, 'peer_meta, 'conn_meta) connection option ;
  disconnect :
    ?wait:bool -> ('msg, 'peer_meta, 'conn_meta) connection -> unit Lwt.t ;
  connection_info :
    ('msg, 'peer_meta, 'conn_meta) connection -> 'conn_meta P2p_connection.Info.t ;
  connection_local_metadata :
    ('msg, 'peer_meta, 'conn_meta) connection -> 'conn_meta ;
  connection_remote_metadata :
    ('msg, 'peer_meta, 'conn_meta) connection -> 'conn_meta ;
  connection_stat : ('msg, 'peer_meta, 'conn_meta) connection -> P2p_stat.t ;
  global_stat : unit -> P2p_stat.t ;
  get_peer_metadata : P2p_peer.Id.t -> 'peer_meta ;
  set_peer_metadata : P2p_peer.Id.t -> 'peer_meta -> unit ;
  recv : ('msg, 'peer_meta, 'conn_meta) connection -> 'msg tzresult Lwt.t ;
  recv_any : unit -> (('msg, 'peer_meta, 'conn_meta) connection * 'msg) Lwt.t ;
  send :
    ('msg, 'peer_meta, 'conn_meta) connection -> 'msg -> unit tzresult Lwt.t ;
  try_send : ('msg, 'peer_meta, 'conn_meta) connection -> 'msg -> bool ;
  broadcast : 'msg -> unit ;
  pool : ('msg, 'peer_meta, 'conn_meta) P2p_pool.t option ;
  fold_connections :
    'a. init: 'a ->
    f:(P2p_peer.Id.t ->
       ('msg, 'peer_meta, 'conn_meta) connection -> 'a -> 'a) -> 'a ;
  iter_connections :
    (P2p_peer.Id.t ->
     ('msg, 'peer_meta, 'conn_meta) connection -> unit) -> unit ;
  on_new_connection :
    (P2p_peer.Id.t ->
     ('msg, 'peer_meta, 'conn_meta) connection -> unit) -> unit ;
  activate : unit -> unit ;
}
type ('msg, 'peer_meta, 'conn_meta) net = ('msg, 'peer_meta, 'conn_meta) t

let announced_version net = net.announced_version

let pool net = net.pool

let check_limits =
  let fail_1 v orig =
    if not (Ptime.Span.compare v Ptime.Span.zero <= 0) then
      return_unit
    else
      Error_monad.failwith "value of option %S cannot be negative or null@."
        orig
  in
  let fail_2 v orig =
    if not (v < 0) then
      return_unit
    else
      Error_monad.failwith "value of option %S cannot be negative@." orig
  in
  fun c ->
    fail_1 c.authentication_timeout
      "authentication-timeout" >>=? fun () ->
    fail_2 c.min_connections
      "min-connections" >>=? fun () ->
    fail_2 c.expected_connections
      "expected-connections" >>=? fun () ->
    fail_2 c.max_connections
      "max-connections" >>=? fun () ->
    fail_2 c.max_incoming_connections
      "max-incoming-connections" >>=? fun () ->
    fail_2 c.read_buffer_size
      "read-buffer-size" >>=? fun () ->
    fail_2 c.known_peer_ids_history_size
      "known-peer-ids-history-size" >>=? fun () ->
    fail_2 c.known_points_history_size
      "known-points-history-size" >>=? fun () ->
    fail_1 c.swap_linger
      "swap-linger" >>=? fun () ->
    begin
      match c.binary_chunks_size with
      | None -> return_unit
      | Some size -> P2p_socket.check_binary_chunks_size size
    end >>=? fun () ->
    return_unit

let create ~config ~limits peer_cfg conn_cfg msg_cfg =
  check_limits limits >>=? fun () ->
  Real.create ~config ~limits peer_cfg conn_cfg msg_cfg  >>=? fun net ->
  return {
    announced_version =
      Network_version.announced
        ~chain_name: msg_cfg.chain_name
        ~distributed_db_versions: msg_cfg.distributed_db_versions
        ~p2p_versions: P2p_version.supported ;
    peer_id = Real.peer_id net ;
    maintain = Real.maintain net ;
    roll = Real.roll net  ;
    shutdown = Real.shutdown net  ;
    connections = Real.connections net  ;
    find_connection = Real.find_connection net ;
    disconnect = Real.disconnect ;
    connection_info = Real.connection_info net  ;
    connection_local_metadata = Real.connection_local_metadata net  ;
    connection_remote_metadata = Real.connection_remote_metadata net  ;
    connection_stat = Real.connection_stat net ;
    global_stat = Real.global_stat net ;
    get_peer_metadata = Real.get_peer_metadata net ;
    set_peer_metadata = Real.set_peer_metadata net ;
    recv = Real.recv net ;
    recv_any = Real.recv_any net ;
    send = Real.send net ;
    try_send = Real.try_send net ;
    broadcast = Real.broadcast net ;
    pool = Some net.pool ;
    fold_connections = (fun ~init ~f -> Real.fold_connections net ~init ~f) ;
    iter_connections = Real.iter_connections net ;
    on_new_connection = Real.on_new_connection net ;
    activate = Real.activate net ;
  }

let activate t =
  log_info "activate P2P layer !";
  t.activate ()

let faked_network (msg_cfg : 'msg message_config) peer_cfg faked_metadata =
  let announced_version =
    Network_version.announced
      ~chain_name: msg_cfg.chain_name
      ~distributed_db_versions: msg_cfg.distributed_db_versions
      ~p2p_versions: P2p_version.supported in
  {
    announced_version ;
    peer_id = Fake.id.peer_id ;
    maintain = Lwt.return ;
    roll = Lwt.return ;
    shutdown = Lwt.return ;
    connections = (fun () -> []) ;
    find_connection = (fun _ -> None) ;
    disconnect = (fun ?wait:_ _ -> Lwt.return_unit) ;
    connection_info =
      (fun _ -> Fake.connection_info announced_version faked_metadata) ;
    connection_local_metadata = (fun _ -> faked_metadata) ;
    connection_remote_metadata = (fun _ -> faked_metadata) ;
    connection_stat = (fun _ -> Fake.empty_stat) ;
    global_stat = (fun () -> Fake.empty_stat) ;
    get_peer_metadata = (fun _ -> peer_cfg.peer_meta_initial ()) ;
    set_peer_metadata = (fun _ _ -> ()) ;
    recv = (fun _ -> Lwt_utils.never_ending ()) ;
    recv_any = (fun () -> Lwt_utils.never_ending ()) ;
    send = (fun _ _ -> fail P2p_errors.Connection_closed) ;
    try_send = (fun _ _ -> false) ;
    fold_connections = (fun ~init ~f:_ -> init) ;
    iter_connections = (fun _f -> ()) ;
    on_new_connection = (fun _f -> ()) ;
    broadcast = ignore ;
    pool = None ;
    activate = (fun _ -> ()) ;
  }

let peer_id net = net.peer_id
let maintain net = net.maintain ()
let roll net = net.roll ()
let shutdown net = net.shutdown ()
let connections net = net.connections ()
let disconnect net = net.disconnect
let find_connection net = net.find_connection
let connection_info net = net.connection_info
let connection_local_metadata net = net.connection_local_metadata
let connection_remote_metadata net = net.connection_remote_metadata
let connection_stat net = net.connection_stat
let global_stat net = net.global_stat ()
let get_peer_metadata net = net.get_peer_metadata
let set_peer_metadata net = net.set_peer_metadata
let recv net = net.recv
let recv_any net = net.recv_any ()
let send net = net.send
let try_send net = net.try_send
let broadcast net = net.broadcast
let fold_connections net = net.fold_connections
let iter_connections net = net.iter_connections
let on_new_connection net = net.on_new_connection

let greylist_addr net addr =
  Option.iter net.pool ~f:(fun pool -> P2p_pool.greylist_addr pool addr)
let greylist_peer net peer_id =
  Option.iter net.pool ~f:(fun pool -> P2p_pool.greylist_peer pool peer_id)
