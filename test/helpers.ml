open! Core
open! Exchange_core

let acct n = Account.of_string (sprintf "0x%040x" n)
let px = Price.of_string
let sz = Size.of_string
let usd = Usd.of_string
let btc = Symbol.of_string "BTC"
