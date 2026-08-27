let ( let* ) = Lwt.bind

type error = { code : Errors.Code.t; message : string }

let make_error code message =
  match Errors.Code.of_string code with
  | Ok code -> { code; message }
  | Error _ -> failwith "internal HTTP error code is invalid"

let error_code error = error.code
let error_message error = error.message
let invalid_policy = make_error "HTTP_INVALID_POLICY" "HTTP policy is invalid"

let invalid_request =
  make_error "HTTP_INVALID_REQUEST" "HTTP request is invalid"

let request_too_large =
  make_error "HTTP_REQUEST_TOO_LARGE" "HTTP request body is too large"

let response_too_large =
  make_error "HTTP_RESPONSE_TOO_LARGE" "HTTP response body is too large"

let attempt_timeout = make_error "HTTP_ATTEMPT_TIMEOUT" "HTTP attempt timed out"

let total_timeout =
  make_error "HTTP_TOTAL_TIMEOUT" "HTTP total deadline expired"

let transport_failed =
  make_error "HTTP_TRANSPORT_FAILED" "HTTP transport failed"

let decode_failed =
  make_error "HTTP_DECODE_FAILED" "HTTP response decoding failed"

let cancelled = make_error "HTTP_CANCELLED" "HTTP request was cancelled"

type meth = [ `GET | `HEAD | `POST | `PUT | `PATCH | `DELETE ]

type policy = {
  total_timeout_s : float;
  attempt_timeout_s : float;
  max_attempts : int;
  initial_backoff_s : float;
  max_backoff_s : float;
  max_retry_after_s : float;
  max_request_bytes : int;
  max_response_bytes : int;
}

type request = {
  meth : meth;
  uri : Uri.t;
  headers : (string * string) list;
  body : bytes;
  idempotency_key : string option;
}

type _ decoder = Bytes : bytes decoder | Json : Yojson.Safe.t decoder
type 'a response = { status : int; body : 'a; attempts : int }
type t = { policy : policy; pool : unit Lwt_pool.t }

let policy ~total_timeout_s ~attempt_timeout_s ~max_attempts ~initial_backoff_s
    ~max_backoff_s ~max_retry_after_s ~max_request_bytes ~max_response_bytes =
  let finite_positive value = Float.is_finite value && value > 0.0 in
  if
    (not (finite_positive total_timeout_s))
    || (not (finite_positive attempt_timeout_s))
    || attempt_timeout_s > total_timeout_s
    || max_attempts < 1 || max_attempts > 10
    || (not (Float.is_finite initial_backoff_s))
    || initial_backoff_s < 0.0
    || (not (Float.is_finite max_backoff_s))
    || max_backoff_s < initial_backoff_s
    || (not (Float.is_finite max_retry_after_s))
    || max_retry_after_s < 0.0 || max_request_bytes < 0
    || max_request_bytes > 16_777_216
    || max_response_bytes < 1
    || max_response_bytes > 16_777_216
  then Error invalid_policy
  else
    Ok
      {
        total_timeout_s;
        attempt_timeout_s;
        max_attempts;
        initial_backoff_s;
        max_backoff_s;
        max_retry_after_s;
        max_request_bytes;
        max_response_bytes;
      }

let create ~max_concurrency policy =
  if max_concurrency < 1 || max_concurrency > 1_024 then Error invalid_policy
  else
    Ok
      {
        policy;
        pool = Lwt_pool.create max_concurrency (fun () -> Lwt.return_unit);
      }

let bytes = Bytes
let json = Json

let valid_header_name value =
  String.length value > 0
  && String.for_all
       (function
         | 'a' .. 'z'
         | 'A' .. 'Z'
         | '0' .. '9'
         | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^'
         | '_' | '`' | '|' | '~' ->
             true
         | _ -> false)
       value

let valid_header (name, value) =
  valid_header_name name
  && (not (String.contains value '\r'))
  && (not (String.contains value '\n'))
  && String.lowercase_ascii name <> "idempotency-key"

let valid_idempotency value =
  let length = String.length value in
  length >= 8 && length <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' -> true
         | _ -> false)
       value

let option_exists predicate = function
  | Some value -> predicate value
  | None -> false

let option_for_all predicate = function
  | Some value -> predicate value
  | None -> true

let valid_uri uri =
  (match Uri.scheme uri with Some "http" | Some "https" -> true | _ -> false)
  && option_exists (fun host -> String.trim host <> "") (Uri.host uri)
  && Option.is_none (Uri.userinfo uri)
  && option_for_all (fun port -> port >= 1 && port <= 65_535) (Uri.port uri)

let request ~meth ~uri ?(headers = []) ?(body = Bytes.empty) ?idempotency_key ()
    =
  if (not (valid_uri uri)) || not (List.for_all valid_header headers) then
    Error invalid_request
  else if Bytes.length body > 16_777_216 then Error request_too_large
  else if not (option_for_all valid_idempotency idempotency_key) then
    Error invalid_request
  else Ok { meth; uri; headers; body = Bytes.copy body; idempotency_key }

let status response = response.status
let body response = response.body
let attempts response = response.attempts

let cohttp_meth : meth -> Cohttp.Code.meth = function
  | `GET -> `GET
  | `HEAD -> `HEAD
  | `POST -> `POST
  | `PUT -> `PUT
  | `PATCH -> `PATCH
  | `DELETE -> `DELETE

let request_headers request =
  let headers = Cohttp.Header.of_list request.headers in
  match request.idempotency_key with
  | None -> headers
  | Some key -> Cohttp.Header.add headers "idempotency-key" key

let retryable_status = function
  | 408 | 425 | 429 | 500 | 502 | 503 | 504 -> true
  | _ -> false

let retryable_request request =
  match request.meth with
  | `GET | `HEAD | `PUT | `DELETE -> true
  | `POST | `PATCH -> Option.is_some request.idempotency_key

let read_capped ~maximum body =
  let stream = Cohttp_lwt.Body.to_stream body in
  let buffer = Buffer.create (min maximum 4096) in
  let rec consume size =
    let* chunk = Lwt_stream.get stream in
    match chunk with
    | None -> Lwt.return (Ok (Bytes.of_string (Buffer.contents buffer)))
    | Some chunk when size + String.length chunk > maximum ->
        let* () = Cohttp_lwt.Body.drain_body body in
        Lwt.return (Error response_too_large)
    | Some chunk ->
        Buffer.add_string buffer chunk;
        consume (size + String.length chunk)
  in
  Lwt.catch
    (fun () -> consume 0)
    (fun error ->
      let* () =
        Lwt.catch
          (fun () -> Cohttp_lwt.Body.drain_body body)
          (fun _ -> Lwt.return_unit)
      in
      Lwt.fail error)

let decode : type value. value decoder -> bytes -> (value, error) result =
 fun decoder payload ->
  match decoder with
  | Bytes -> Ok payload
  | Json -> (
      try Ok (Yojson.Safe.from_string (Bytes.to_string payload))
      with Yojson.Json_error _ -> Error decode_failed)

let month_number = function
  | "Jan" -> Some 1
  | "Feb" -> Some 2
  | "Mar" -> Some 3
  | "Apr" -> Some 4
  | "May" -> Some 5
  | "Jun" -> Some 6
  | "Jul" -> Some 7
  | "Aug" -> Some 8
  | "Sep" -> Some 9
  | "Oct" -> Some 10
  | "Nov" -> Some 11
  | "Dec" -> Some 12
  | _ -> None

let days_from_civil year month day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let yoe = year - (era * 400) in
  let shifted_month = month + if month > 2 then -3 else 9 in
  let day_of_year = (((153 * shifted_month) + 2) / 5) + day - 1 in
  let day_of_era = (yoe * 365) + (yoe / 4) - (yoe / 100) + day_of_year in
  (era * 146097) + day_of_era - 719468

let leap_year year = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)

let days_in_month year = function
  | 2 -> if leap_year year then 29 else 28
  | 4 | 6 | 9 | 11 -> 30
  | _ -> 31

let weekday_number = function
  | "Sun" -> Some 0
  | "Mon" -> Some 1
  | "Tue" -> Some 2
  | "Wed" -> Some 3
  | "Thu" -> Some 4
  | "Fri" -> Some 5
  | "Sat" -> Some 6
  | _ -> None

let parse_http_date value =
  if String.length value <> 29 || String.sub value 26 3 <> "GMT" then None
  else
    try
      Scanf.sscanf value "%3s, %d %3s %d %d:%d:%d GMT"
        (fun weekday day month year hour minute second ->
          match (month_number month, weekday_number weekday) with
          | Some month, Some weekday
            when year >= 1970 && day >= 1
                 && day <= days_in_month year month
                 && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59
                 && second >= 0 && second <= 59 ->
              let days = days_from_civil year month day in
              if (days + 4) mod 7 <> weekday then None
              else
                Some
                  (float_of_int
                     ((days * 86_400) + (hour * 3_600) + (minute * 60) + second))
          | _ -> None)
    with _ -> None

let local_backoff policy attempt =
  let multiplier = 2. ** float_of_int (attempt - 1) in
  min policy.max_backoff_s (policy.initial_backoff_s *. multiplier)

let retry_delay policy attempt headers now =
  let fallback = local_backoff policy attempt in
  match Cohttp.Header.get headers "retry-after" with
  | None -> fallback
  | Some value -> (
      match int_of_string_opt value with
      | Some seconds when seconds >= 0 ->
          min policy.max_retry_after_s (float_of_int seconds)
      | Some _ -> fallback
      | None -> (
          match parse_http_date value with
          | Some timestamp when timestamp >= now ->
              min policy.max_retry_after_s (timestamp -. now)
          | _ -> fallback))

type attempt_result =
  | Received of int * Cohttp.Header.t * bytes
  | Body_too_large
  | Timed_out
  | Transport_failed
  | Cancelled

let perform_attempt client request timeout_s =
  let operation () =
    let headers = request_headers request in
    let body = Cohttp_lwt.Body.of_string (Bytes.to_string request.body) in
    let* response, response_body =
      Cohttp_lwt_unix.Client.call ~headers ~body (cohttp_meth request.meth)
        request.uri
    in
    let status =
      Cohttp.Response.status response |> Cohttp.Code.code_of_status
    in
    let headers = Cohttp.Response.headers response in
    let* payload =
      read_capped ~maximum:client.policy.max_response_bytes response_body
    in
    match payload with
    | Ok payload -> Lwt.return (Received (status, headers, payload))
    | Error _ -> Lwt.return Body_too_large
  in
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout timeout_s operation)
    (function
      | Lwt.Canceled -> Lwt.return Cancelled
      | Lwt_unix.Timeout -> Lwt.return Timed_out
      | _ -> Lwt.return Transport_failed)

let sleep_with_budget delay deadline =
  let remaining = deadline -. Unix.gettimeofday () in
  if remaining <= 0.0 || delay >= remaining then Lwt.return false
  else
    let* () = Lwt_unix.sleep delay in
    Lwt.return true

let perform_pooled_attempt client request ~remaining ~timeout_s =
  Lwt.catch
    (fun () ->
      Lwt_unix.with_timeout remaining (fun () ->
          Lwt_pool.use client.pool (fun () ->
              perform_attempt client request timeout_s)))
    (function
      | Lwt.Canceled -> Lwt.return Cancelled
      | Lwt_unix.Timeout -> Lwt.return Timed_out
      | _ -> Lwt.return Transport_failed)

let call client ~decoder (request : request) =
  if Bytes.length request.body > client.policy.max_request_bytes then
    Lwt.return (Error request_too_large)
  else
    let deadline = Unix.gettimeofday () +. client.policy.total_timeout_s in
    let rec loop attempt =
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then Lwt.return (Error total_timeout)
      else
        let timeout_s = min client.policy.attempt_timeout_s remaining in
        let* outcome =
          perform_pooled_attempt client request ~remaining ~timeout_s
        in
        handle_outcome attempt outcome
    and handle_outcome attempt = function
      | Body_too_large -> Lwt.return (Error response_too_large)
      | Transport_failed -> Lwt.return (Error transport_failed)
      | Cancelled -> Lwt.return (Error cancelled)
      | Timed_out when retryable_request request ->
          retry_or_timeout attempt None
      | Timed_out -> Lwt.return (Error attempt_timeout)
      | Received (status, headers, _payload)
        when retryable_status status && retryable_request request ->
          retry_or_timeout attempt (Some headers)
      | Received (status, _, payload) ->
          Lwt.return
            (Result.map
               (fun body -> { status; body; attempts = attempt })
               (decode decoder payload))
    and retry_or_timeout attempt headers =
      if attempt >= client.policy.max_attempts then
        if Unix.gettimeofday () >= deadline then
          Lwt.return (Error total_timeout)
        else Lwt.return (Error attempt_timeout)
      else
        let now = Unix.gettimeofday () in
        let delay =
          match headers with
          | None -> local_backoff client.policy attempt
          | Some headers -> retry_delay client.policy attempt headers now
        in
        let* can_continue = sleep_with_budget delay deadline in
        if can_continue then loop (attempt + 1)
        else Lwt.return (Error total_timeout)
    in
    loop 1
