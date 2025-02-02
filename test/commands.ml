open! Core
open  Async
open  Redis
open  Deferred.Or_error.Let_syntax
module Expect_test_config = Expect_test_config_with_unit_expect_or_error
module R                  = Redis.Make (Bulk_io.String) (Bulk_io.String)

let with_sandbox f =
  let%bind         where_to_connect = Sandbox.where_to_connect ()   in
  let%bind         r                = R.create ~where_to_connect () in
  let%bind         ()               = f r                           in
  let%map.Deferred ()               = R.close r                     in
  Ok ()
;;

let%expect_test "Strings" =
  with_sandbox (fun r ->
    let%bind response = R.exists r [ "hello" ] in
    [%test_eq: int] response 0;
    let%bind ()       = R.set r "hello" "world" in
    let%bind response = R.exists r [ "hello" ]  in
    [%test_eq: int] response 1;
    let%bind response = R.dbsize r in
    [%test_eq: int] response 1;
    let%bind response = R.get r "hello" in
    print_s ([%sexp_of: string option] response);
    [%expect {| (world) |}];
    let%bind response = R.get r "bork" in
    print_s ([%sexp_of: string option] response);
    [%expect {| () |}];
    let%bind () = R.select r 1                              in
    let%bind () = R.mset r [ "a", "b"; "c", "d"; "e", "f" ] in
    let%bind response = R.del r [ "c"; "g" ]                in
    print_s ([%sexp_of: int] response);
    [%expect {|
      1 |}];
    let%bind response = R.mget r [ "hello"; "a"; "c"; "e" ] in
    print_s ([%sexp_of: string option list] response);
    [%expect {| (() (b) () (f)) |}];
    let%bind response = R.setnx r "color" "blue" in
    print_s ([%sexp_of: bool] response);
    [%expect {| true |}];
    let%bind response = R.setnx r "color" "green" in
    [%test_eq: bool] response false;
    let%bind response = R.get r "color" in
    print_s ([%sexp_of: string option] response);
    [%expect {| (blue) |}];
    (* Special case for empty variadic inputs *)
    let%bind ()       = R.mset r [] in
    let%bind response = R.mget r [] in
    [%test_eq: string option list] response [];
    let%bind response = R.del r [] in
    [%test_eq: int] response 0;
    let%bind `Cursor cursor, scan0 = R.scan r ~cursor:0 ~count:1 () in
    let%bind `Cursor cursor, scan1 = R.scan r ~cursor            () in
    (* The SCAN test is written to show summary results because this command is
       intentionally non-deterministic (see documentation) *)
    print_s
      ([%sexp_of: int * string list]
         (cursor, List.dedup_and_sort ~compare:String.compare (scan0 @ scan1)));
    [%expect {| (0 (a color e)) |}];
    return ())
;;

let%expect_test "Command: keys" =
  with_sandbox (fun r ->
    let%bind () =
      R.mset r [ "a", "b"; "c", "d"; "e", "f"; "foo", "g"; "foobar", "h" ]
    in
    let%bind response = R.keys r >>| List.sort ~compare:String.compare in
    print_s ([%sexp_of: string list] response);
    [%expect {| (a c e foo foobar) |}];
    let%bind response =
      R.keys r ~pattern:"foo*" >>| List.sort ~compare:String.compare
    in
    print_s ([%sexp_of: string list] response);
    [%expect {| (foo foobar) |}];
    return ())
;;

let%expect_test "set commands" =
  with_sandbox (fun r ->
    let key_1 = "1" in
    let query_and_print_members key =
      let%map members_unsorted = R.smembers r key in
      (* Sorting here is important because redis represents the values as an unordered
         set, and so the return order will not be deterministic. *)
      let members = List.sort members_unsorted ~compare:String.compare in
      print_s ([%sexp_of: string list] members)
    in
    let%bind response = R.sadd r key_1 [ "a"; "b"; "c"; "d" ] in
    [%test_eq: int] response 4;
    let%bind () = query_and_print_members key_1 in
    [%expect {| (a b c d) |}];
    let%bind response = R.sadd r key_1 [ "c"; "d"; "e"; "f" ] in
    [%test_eq: int] response 2;
    let%bind () = query_and_print_members key_1 in
    [%expect {| (a b c d e f) |}];
    let%bind response = R.srem r key_1 [ "a"; "b"; "d"; "g" ] in
    [%test_eq: int] response 3;
    let%bind () = query_and_print_members key_1 in
    [%expect {| (c e f) |}];
    return ())
;;

let%expect_test "Parallel" =
  with_sandbox (fun r ->
    let values = List.init 10000 ~f:(fun i -> Int.to_string i, Int.to_string i) in
    let%bind _error =
      let%map.Deferred errors =
        Deferred.List.map values ~how:`Parallel ~f:(fun (k, v) -> R.set r k v)
      in
      Or_error.combine_errors errors
    in
    let%bind _error =
      let%map.Deferred errors =
        Deferred.List.map values ~how:`Parallel ~f:(fun (k, v) ->
          let%map response = R.get r k in
          if not (Option.equal String.equal (Some v) response)
          then print_s ([%sexp_of: string option] response))
      in
      Or_error.combine_errors errors
    in
    return ())
;;

let%expect_test "Bin_prot" =
  let module Key = struct
    module T = struct
      type t = { msg : string } [@@deriving bin_io, sexp_of]
    end

    include T
    include Bulk_io.Make_binable (T)
  end
  in
  let module Value = struct
    module T = struct
      type t =
        { color  : string
        ; number : int
        }
      [@@deriving bin_io, sexp_of]
    end

    include T
    include Bulk_io.Make_binable (T)
  end
  in
  let module Int_value = struct
    include Int
    include Bulk_io.Make_binable (Int)
  end
  in
  let module R = Redis.Make (Key) (Value) in
  let%bind where_to_connect = Sandbox.where_to_connect ()                           in
  let%bind r = R.create ~where_to_connect ()                                        in
  let%bind () = R.set r { Key.msg = "hello" } { Value.color = "blue"; number = 42 } in
  let%bind response = R.get r { Key.msg = "hello" }                                 in
  print_s ([%sexp_of: Value.t option] response);
  [%expect {| (((color blue) (number 42))) |}];
  let module Redis_with_too_small_value = Redis.Make (Key) (Int_value) in
  let%bind          r        = Redis_with_too_small_value.create ~where_to_connect () in
  let%bind.Deferred response = Redis_with_too_small_value.get r { Key.msg = "hello" } in
  print_s ([%sexp_of: int option Or_error.t] response);
  [%expect {| (Error "Bin_prot should have read 6 bytes but read 1") |}];
  let module Wrong_value = struct
    module T = struct
      type t = [ `Will_not_parse of int ] [@@deriving bin_io, sexp_of]
    end

    include T
    include Bulk_io.Make_binable (T)
  end
  in
  let module Redis_with_wrong_value = Redis.Make (Key) (Wrong_value) in
  let%bind          r        = Redis_with_wrong_value.create ~where_to_connect () in
  let%bind.Deferred response = Redis_with_wrong_value.get r { Key.msg = "hello" } in
  print_s ([%sexp_of: Wrong_value.t option Or_error.t] response);
  [%expect {| (Error (common.ml.Read_error Variant_tag 4)) |}];
  return ()
;;

let%expect_test "Invalidation" =
  let%bind where_to_connect = Sandbox.where_to_connect   () in
  let%bind reader           = R.create ~where_to_connect () in
  let%bind writer           = R.create ~where_to_connect () in
  let%bind invalidation     = R.client_tracking reader   () in
  let expect_invalidation () =
    let%map.Deferred result = Pipe.read invalidation in
    Ok (print_s ([%sexp_of: [ `Ok of [ `All | `Key of string ] | `Eof ]] result))
  in
  let%bind response = R.get reader "hello" in
  print_s ([%sexp_of: string option] response);
  [%expect {| () |}];
  let%bind () = R.set writer "hello" "world" in
  let%bind () = expect_invalidation ()       in
  [%expect {| (Ok (Key hello)) |}];
  let%bind () = R.flushall writer      in
  let%bind () = expect_invalidation () in
  [%expect {| (Ok All) |}];
  let%bind () = R.flushdb reader       in
  let%bind () = expect_invalidation () in
  [%expect {| (Ok All) |}];
  Pipe.close_read invalidation;
  return ()
;;

let%expect_test "Broadcast invalidation" =
  let%bind where_to_connect = Sandbox.where_to_connect             () in
  let%bind reader           = R.create ~where_to_connect           () in
  let%bind writer           = R.create ~where_to_connect           () in
  let%bind invalidation     = R.client_tracking ~bcast:true reader () in
  let expect_invalidation () =
    let%map.Deferred result = Pipe.read invalidation in
    Ok (print_s ([%sexp_of: [ `Ok of [ `All | `Key of string ] | `Eof ]] result))
  in
  let%bind () = R.set writer "hello" "world" in
  (* Reader receives bcast invalidation without first requesting any keys *)
  let%bind () = expect_invalidation ()       in
  [%expect {| (Ok (Key hello)) |}];
  let%bind () = R.flushall writer      in
  let%bind () = expect_invalidation () in
  [%expect {| (Ok All) |}];
  Pipe.close_read invalidation;
  return ()
;;

let%expect_test "Large message" =
  (* This intends to exercise the Need_more_data logic in Client.read. This is a good test
     for the negative case but not the positive one. That is: we don't have a way to prove
     that this test is doing its job other than commenting out Need_more_data logic and
     making sure the test fails, as behavior depends on timing as well as how the OS
     buffers the large message. *)
  with_sandbox (fun r ->
    let%bind _ = R.echo r (String.init 1000000 ~f:(fun _ -> 'x')) in
    [%expect {| |}];
    return ())
;;

let%expect_test "Sending a bulk that is too big will fail" =
  with_sandbox (fun r ->
    let count = 1_000_000 in
    let%bind.Deferred response =
      R.mset r (List.init count ~f:(fun i -> Int.to_string i, Int.to_string i))
    in
    print_s ([%sexp_of: unit Or_error.t] response);
    [%expect {| (Error "ERR Protocol error: invalid multibulk length") |}];
    return ())
;;

let%expect_test "Bulk messages up to maximum size works" =
  with_sandbox (fun r ->
    let count = 511_482 in
    let%bind () =
      R.mset r (List.init count ~f:(fun i -> Int.to_string i, Int.to_string i))
    in
    let%bind.Deferred response =
      R.mget r (List.init count ~f:(fun i -> Int.to_string i))
    in
    print_s ([%sexp_of: unit Or_error.t] (Or_error.ignore_m response));
    [%expect {| (Ok ()) |}];
    return ())
;;

let%expect_test "Disconnect **THIS TEST MUST BE LAST**" =
  let%bind where_to_connect = Sandbox.where_to_connect () in
  let on_disconnect () = print_endline "on_disconnect" in
  let%bind          r        = R.create ~on_disconnect ~where_to_connect () in
  let%bind.Deferred response = R.shutdown r                                 in
  print_s ([%sexp_of: unit Or_error.t] response);
  [%expect {|
    on_disconnect
    (Error Disconnected) |}];
  let%bind.Deferred response = R.echo r "hello" in
  print_s ([%sexp_of: string Or_error.t] response);
  [%expect {| (Error Disconnected) |}];
  return ()
;;
