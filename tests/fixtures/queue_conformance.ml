open Lwt.Infix

module type QUEUE_BACKEND = sig
  type t
  type queue
  type payload
  type error_kind = [ `Full | `Payload_too_large | `Closed | `Other ]

  val make_queue :
    t -> name:string -> max_depth:int -> max_payload_bytes:int -> queue

  val bytes : bytes -> payload
  val json : Yojson.Safe.t -> payload
  val enqueue : t -> queue -> payload -> (unit, error_kind) result Lwt.t
  val dequeue : t -> queue -> (payload option, error_kind) result Lwt.t
  val payload_equal : payload -> payload -> bool
  val close : t -> unit Lwt.t
end

type 'backend case = { name : string; run : 'backend -> unit Lwt.t }

let fail format = Printf.ksprintf failwith format

let expect_ok label = function
  | Ok value -> value
  | Error _ -> fail "%s failed" label

let expect_error label expected = function
  | Error actual when actual = expected -> ()
  | Error _ -> fail "%s returned the wrong error" label
  | Ok _ -> fail "%s unexpectedly succeeded" label

module Make (Backend : QUEUE_BACKEND) = struct
  let check_payload label expected actual =
    if not (Backend.payload_equal expected actual) then
      fail "%s returned a different payload" label

  let dequeue_one backend queue label =
    let open Lwt.Syntax in
    let+ result = Backend.dequeue backend queue in
    match expect_ok label result with
    | Some payload -> payload
    | None -> fail "%s returned an empty queue" label

  let fifo_bytes_and_json backend =
    let open Lwt.Syntax in
    let queue =
      Backend.make_queue backend ~name:"conformance-fifo" ~max_depth:4
        ~max_payload_bytes:128
    in
    let first = Backend.bytes (Bytes.of_string "one\000two") in
    let second =
      Backend.json (`Assoc [ ("job", `String "two"); ("n", `Int 2) ])
    in
    let* () =
      Backend.enqueue backend queue first >|= expect_ok "enqueue bytes"
    in
    let* () =
      Backend.enqueue backend queue second >|= expect_ok "enqueue JSON"
    in
    let* actual_first = dequeue_one backend queue "dequeue bytes" in
    check_payload "byte FIFO" first actual_first;
    let* actual_second = dequeue_one backend queue "dequeue JSON" in
    check_payload "JSON FIFO" second actual_second;
    Lwt.return_unit

  let empty_nonblocking backend =
    let open Lwt.Syntax in
    let queue =
      Backend.make_queue backend ~name:"conformance-empty" ~max_depth:1
        ~max_payload_bytes:16
    in
    let+ result = Backend.dequeue backend queue in
    match expect_ok "empty dequeue" result with
    | None -> ()
    | Some _ -> fail "empty dequeue returned a payload"

  let exact_payload_boundaries backend =
    let open Lwt.Syntax in
    let bytes_queue =
      Backend.make_queue backend ~name:"conformance-bytes-cap" ~max_depth:2
        ~max_payload_bytes:16
    in
    let json_queue =
      Backend.make_queue backend ~name:"conformance-json-cap" ~max_depth:2
        ~max_payload_bytes:16
    in
    let bytes_exact = Backend.bytes (Bytes.make 16 'b') in
    let bytes_over = Backend.bytes (Bytes.make 17 'b') in
    let json_exact = Backend.json (`String (String.make 14 'j')) in
    let json_over = Backend.json (`String (String.make 15 'j')) in
    let* () =
      Backend.enqueue backend bytes_queue bytes_exact
      >|= expect_ok "exact byte cap"
    in
    let* () =
      Backend.enqueue backend bytes_queue bytes_over
      >|= expect_error "byte cap plus one" `Payload_too_large
    in
    let* () =
      Backend.enqueue backend json_queue json_exact
      >|= expect_ok "exact JSON cap"
    in
    Backend.enqueue backend json_queue json_over
    >|= expect_error "JSON cap plus one" `Payload_too_large

  let max_depth_no_drop backend =
    let open Lwt.Syntax in
    let queue =
      Backend.make_queue backend ~name:"conformance-depth" ~max_depth:3
        ~max_payload_bytes:32
    in
    let payloads =
      List.map
        (fun value -> Backend.bytes (Bytes.of_string value))
        [ "first"; "second"; "third" ]
    in
    let* () =
      Lwt_list.iter_s
        (fun payload ->
          Backend.enqueue backend queue payload >|= expect_ok "depth admission")
        payloads
    in
    let* () =
      Backend.enqueue backend queue (Backend.bytes (Bytes.of_string "rejected"))
      >|= expect_error "full queue" `Full
    in
    let* drained =
      Lwt_list.map_s
        (fun _ -> dequeue_one backend queue "depth dequeue")
        payloads
    in
    List.iter2 (check_payload "max-depth FIFO") payloads drained;
    let+ final = Backend.dequeue backend queue in
    match expect_ok "post-drain dequeue" final with
    | None -> ()
    | Some _ -> fail "max-depth queue retained an unexpected payload"

  let concurrent_atomic_admission backend =
    let open Lwt.Syntax in
    let queue =
      Backend.make_queue backend ~name:"conformance-concurrent" ~max_depth:16
        ~max_payload_bytes:32
    in
    let payloads =
      List.init 64 (fun index ->
          Backend.bytes (Bytes.of_string (Printf.sprintf "item-%02d" index)))
    in
    let* admissions =
      Lwt.all (List.map (Backend.enqueue backend queue) payloads)
    in
    let accepted, full, other =
      List.fold_left
        (fun (accepted, full, other) -> function
          | Ok () -> (accepted + 1, full, other)
          | Error `Full -> (accepted, full + 1, other)
          | Error _ -> (accepted, full, other + 1))
        (0, 0, 0) admissions
    in
    if (accepted, full, other) <> (16, 48, 0) then
      fail "concurrent admission was accepted=%d full=%d other=%d" accepted full
        other;
    let* drained =
      Lwt_list.map_s
        (fun _ -> dequeue_one backend queue "concurrent dequeue")
        (List.init 16 Fun.id)
    in
    let unique =
      List.fold_left
        (fun seen payload ->
          if List.exists (Backend.payload_equal payload) seen then
            fail "concurrent queue returned a duplicate payload"
          else payload :: seen)
        [] drained
    in
    if List.length unique <> 16 then
      fail "concurrent queue dropped admitted payloads";
    Lwt.return_unit

  let terminal_idempotent_close backend =
    let open Lwt.Syntax in
    let queue =
      Backend.make_queue backend ~name:"conformance-close" ~max_depth:1
        ~max_payload_bytes:16
    in
    let* () = Backend.close backend in
    let* () = Backend.close backend in
    let* () =
      Backend.enqueue backend queue (Backend.bytes (Bytes.of_string "closed"))
      >|= expect_error "enqueue after close" `Closed
    in
    Backend.dequeue backend queue >|= expect_error "dequeue after close" `Closed

  let cases =
    [
      { name = "bytes and JSON FIFO"; run = fifo_bytes_and_json };
      { name = "empty dequeue is nonblocking"; run = empty_nonblocking };
      { name = "exact payload boundaries"; run = exact_payload_boundaries };
      {
        name = "atomic max depth preserves FIFO without drop";
        run = max_depth_no_drop;
      };
      {
        name = "64 concurrent admissions accept exactly 16";
        run = concurrent_atomic_admission;
      };
      {
        name = "close is terminal and idempotent";
        run = terminal_idempotent_close;
      };
    ]
end
