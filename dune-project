(lang dune 3.17)

(name exchange-core)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/exchange-core))

(package
 (name exchange-core)
 (synopsis "Venue-neutral trading primitives and order, account and market views")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  fixed-decimal
  ppx_jane))

(package
 (name exchange-core-engine)
 (synopsis
  "Venue-neutral exchange engine: matching, clearinghouse, margin, funding, liquidation, market simulation")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  fixed-decimal
  exchange-core
  order-book
  ppx_jane))
