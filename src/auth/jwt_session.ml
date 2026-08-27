type claims = { tenant_id : string; user_id : string; role : string; expires_at : float }

let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64 value =
  let output = Buffer.create ((String.length value + 2) / 3 * 4) in
  let get index = Char.code value.[index] in
  let rec loop index =
    if index >= String.length value then ()
    else
      let remaining = String.length value - index in
      let a = get index in
      let b = if remaining > 1 then get (index + 1) else 0 in
      let c = if remaining > 2 then get (index + 2) else 0 in
      Buffer.add_char output alphabet.[a lsr 2];
      Buffer.add_char output alphabet.[((a land 3) lsl 4) lor (b lsr 4)];
      if remaining > 1 then Buffer.add_char output alphabet.[((b land 15) lsl 2) lor (c lsr 6)] else Buffer.add_char output '=';
      if remaining > 2 then Buffer.add_char output alphabet.[c land 63] else Buffer.add_char output '=';
      loop (index + 3)
  in
  loop 0;
  Buffer.contents output

let base64url value =
  base64 value
  |> String.to_seq
  |> Seq.filter (fun character -> character <> '=')
  |> String.of_seq
  |> String.map (function '+' -> '-' | '/' -> '_' | character -> character)

let unbase64 value =
  let normalized = String.map (function '-' -> '+' | '_' -> '/' | character -> character) value in
  let padding = match String.length normalized mod 4 with 0 -> "" | 2 -> "==" | 3 -> "=" | _ -> raise Exit in
  let normalized = normalized ^ padding in
  let value character = match String.index_opt alphabet character with Some index -> index | _ -> raise Exit in
  let output = Buffer.create (String.length normalized / 4 * 3) in
  let rec loop index =
    if index >= String.length normalized then ()
    else
      let a = value normalized.[index] in
      let b = value normalized.[index + 1] in
      Buffer.add_char output (Char.chr ((a lsl 2) lor (b lsr 4)));
      if normalized.[index + 2] <> '=' then begin
        let c = value normalized.[index + 2] in
        Buffer.add_char output (Char.chr (((b land 15) lsl 4) lor (c lsr 2)));
        if normalized.[index + 3] <> '=' then begin
          let d = value normalized.[index + 3] in
          Buffer.add_char output (Char.chr (((c land 3) lsl 6) lor d))
        end
      end;
      loop (index + 4)
  in
  loop 0;
  Buffer.contents output

let secure_equal left right =
  String.length left = String.length right &&
  let difference = ref 0 in
  for index = 0 to String.length left - 1 do difference := !difference lor (Char.code left.[index] lxor Char.code right.[index]) done;
  !difference = 0

let issue ~secret ~tenant_id ~user_id ~role ~ttl_seconds =
  let header = base64url "{\"alg\":\"HS256\",\"typ\":\"JWT\"}" in
  let expires_at = Unix.gettimeofday () +. float_of_int ttl_seconds in
  let payload = Yojson.Safe.to_string (`Assoc [ ("tenant_id", `String tenant_id); ("user_id", `String user_id); ("role", `String role); ("exp", `Float expires_at) ]) |> base64url in
  let unsigned = header ^ "." ^ payload in
  unsigned ^ "." ^ (Digestif.SHA256.hmac_string ~key:secret unsigned |> Digestif.SHA256.to_hex)

let verify ~secret ~token =
  match String.split_on_char '.' token with
  | [ header; payload; signature ] when header <> "" && payload <> "" && secure_equal signature (Digestif.SHA256.hmac_string ~key:secret (header ^ "." ^ payload) |> Digestif.SHA256.to_hex) ->
      (try
         let json = Yojson.Safe.from_string (unbase64 payload) in
         let open Yojson.Safe.Util in
         let claims = { tenant_id = json |> member "tenant_id" |> to_string; user_id = json |> member "user_id" |> to_string; role = json |> member "role" |> to_string; expires_at = json |> member "exp" |> to_float } in
         if claims.expires_at <= Unix.gettimeofday () then Error "AUTH_TOKEN_EXPIRED" else Ok claims
       with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Exit -> Error "AUTH_TOKEN_INVALID")
  | _ -> Error "AUTH_TOKEN_INVALID"
