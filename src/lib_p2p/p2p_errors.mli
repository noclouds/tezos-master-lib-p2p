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

(* p2p io scheduler *)

type error += Connection_closed

(* p2p socket *)

type error += Decipher_error
type error += Invalid_message_size
type error += Encoding_error
type error += Rejected_socket_connection
type error += Rejected_no_common_protocol of { announced : Network_version.t }
type error += Decoding_error
type error += Myself of P2p_connection.Id.t
type error += Not_enough_proof_of_work of P2p_peer.Id.t
type error += Invalid_auth
type error += Invalid_chunks_size of { value: int ; min: int ; max: int }

(* p2p pool *)

type error += Pending_connection
type error += Connected
type error += Connection_refused
type error += Rejected of P2p_peer.Id.t
type error += Too_many_connections
type error += Private_mode
type error += Point_banned of P2p_point.Id.t
type error += Peer_banned of P2p_peer.Id.t
