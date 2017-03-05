let src = Logs.Src.create "nat-packet" ~doc:"Mirage NAT packet parser"
module Log = (val Logs.src_log src : Logs.LOG)

type t =
  [`IPv4 of Ipv4_packet.t * [ `TCP of Tcp.Tcp_packet.t * Cstruct.t
                            | `UDP of Udp_packet.t * Cstruct.t ]
  ]

type error = Format.formatter -> unit

let pp_error f e = e f

let equal_tcp (ah, ap) (bh, bp) =
  Tcp.Tcp_packet.equal ah bh &&
  Cstruct.equal ap bp

let equal_udp (ah, ap) (bh, bp) =
  Udp_packet.equal ah bh &&
  Cstruct.equal ap bp

let equal a b =
  match a, b with
  | `IPv4 (ai, at), `IPv4 (bi, bt) ->
    Ipv4_packet.equal ai bi && (
      match at, bt with
      | `TCP a, `TCP b -> equal_tcp a b
      | `UDP a, `UDP b -> equal_udp a b
      | _ -> false
    )

let of_ipv4_packet packet : (t, error) result =
  match Ipv4_packet.Unmarshal.of_cstruct packet with
  | Error e ->
    Error (fun f -> Fmt.pf f "Failed to parse IPv4 packet: %s@.%a" e Cstruct.hexdump_pp packet)
  | Ok (ip, transport) ->
    match Ipv4_packet.(Unmarshal.int_to_protocol ip.proto) with
    | Some `TCP ->
      begin match Tcp.Tcp_packet.Unmarshal.of_cstruct transport with
        | Error e ->
          Error (fun f -> Fmt.pf f "Failed to parse TCP packet: %s@.%a" e Cstruct.hexdump_pp transport)
        | Ok (tcp, payload) -> Ok (`IPv4 (ip, `TCP (tcp, payload)))
      end
    | Some `UDP ->
      begin match Udp_packet.Unmarshal.of_cstruct transport with
        | Error e ->
          Error (fun f -> Fmt.pf f "Failed to parse UDP packet: %s@.%a" e Cstruct.hexdump_pp transport)
        | Ok (udp, payload) -> Ok (`IPv4 (ip, `UDP (udp, payload)))
      end
    | _ ->
      Error (fun f -> Fmt.pf f "Ignoring non-TCP/UDP packet: %a" Ipv4_packet.pp ip)

let of_ethernet_frame frame =
  match Ethif_packet.Unmarshal.of_cstruct frame with
  | Error e ->
    Error (fun f -> Fmt.pf f "Failed to parse ethernet frame: %s@.%a" e Cstruct.hexdump_pp frame)
  | Ok (eth, packet) ->
    match eth.Ethif_packet.ethertype with
    | Ethif_wire.ARP | Ethif_wire.IPv6 ->
      Error (fun f -> Fmt.pf f "Ignoring a non-IPv4 frame: %a" Cstruct.hexdump_pp frame)
    | Ethif_wire.IPv4 -> of_ipv4_packet packet

let (>>*=) x f =
  match x with
  | Ok x -> f x
  | Error e -> failwith e

let to_cstruct (`IPv4 (ip, transport)) =
  let {Ipv4_packet.src; dst} = ip in
  (* Calculate required buffer size *)
  let transport_header_len =
    match transport with
    | `UDP (udp_header, _) -> Udp_wire.sizeof_udp
    | `TCP (tcp_header, _) ->
      (* TODO: unfortunately, in order to correctly figure out the pseudoheader (and thus the TCP checksum),
       * we need to know the length field of the IPv4 header.  That means we need to know the *overall* length,
       * which means we need to know how many bytes are required to marshal the TCP options. *)
      let options_buf = Cstruct.create 40 in (* 40 is max possible *)
      let options_length = Tcp.Options.marshal options_buf tcp_header.Tcp.Tcp_packet.options in
      Tcp.Tcp_wire.sizeof_tcp + options_length
  in
  (* Write transport headers to second part of buffer.
     We do the transport layer first so that we calculate the correct checksum when we
     write the IP layer. *)
  let transport =
    match transport with
    | `UDP (udp_header, udp_payload) ->
      let pseudoheader = Ipv4_packet.Marshal.pseudoheader ~src ~dst ~proto:`UDP (Cstruct.len udp_payload + Udp_wire.sizeof_udp) in
      let transport_header = Udp_packet.Marshal.make_cstruct
        ~pseudoheader udp_header
        ~payload:udp_payload in
      Logs.debug (fun f -> f "UDP header written: %a" Cstruct.hexdump_pp transport_header);
      [transport_header; udp_payload]
    | `TCP (tcp_header, tcp_payload) ->
      let options_length = transport_header_len - Tcp.Tcp_wire.sizeof_tcp in
      let pseudoheader = Ipv4_packet.Marshal.pseudoheader ~src ~dst ~proto:`TCP (Tcp.Tcp_wire.sizeof_tcp + options_length + Cstruct.len tcp_payload) in
      let transport_header = Tcp.Tcp_packet.Marshal.make_cstruct
        ~pseudoheader tcp_header
        ~payload:tcp_payload in
      Logs.debug (fun f -> f "TCP header written: %a" Cstruct.hexdump_pp transport_header);
      [transport_header; tcp_payload]
  in
  (* Write the IP header to the first part of the buffer. *)
  let ip_payload_len = Cstruct.lenv transport in
  let ip_header = Ipv4_packet.Marshal.make_cstruct ~payload_len:ip_payload_len ip in
  ip_header :: transport

let pp_transport f = function
  | `TCP (tcp, payload) ->
    Fmt.pf f "%a with payload %a"
      Tcp.Tcp_packet.pp tcp
      Cstruct.hexdump_pp payload
  | `UDP (udp, payload) ->
    Fmt.pf f "%a with payload %a"
      Udp_packet.pp udp
      Cstruct.hexdump_pp payload

let pp f = function
  | `IPv4 (ip, transport) ->
    Fmt.pf f "%a %a"
      Ipv4_packet.pp ip
      pp_transport transport