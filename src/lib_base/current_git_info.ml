(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

let raw_commit_hash = "794bc16664cbed4057ffbc51631151023af835c0"

let commit_hash =
  if String.equal raw_commit_hash (""^"794bc16664cbed4057ffbc51631151023af835c0"(*trick to avoid git-subst*))
  then Generated_git_info.commit_hash
  else raw_commit_hash

let raw_abbreviated_commit_hash = "794bc1666"

let abbreviated_commit_hash =
  if String.equal raw_abbreviated_commit_hash (""^"794bc1666")
  then Generated_git_info.abbreviated_commit_hash
  else raw_abbreviated_commit_hash

let raw_committer_date = "2019-08-09 16:37:01 +0000"

let committer_date =
  if String.equal raw_committer_date (""^"2019-08-09 16:37:01 +0000")
  then Generated_git_info.committer_date
  else raw_committer_date
