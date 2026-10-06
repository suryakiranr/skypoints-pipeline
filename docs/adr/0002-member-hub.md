# A Member Hub sits between staging and the Country Tables

"Latest record wins" is resolved once, by a MERGE into a single all-countries Member Hub keyed on Member ID. Country Tables are derived from the hub, and Redemptions join to the hub on Member ID. Without it, a Country Move would mean checking every Country Table, and the redemption join would need a UNION over N tables that grows with each country. The cost is storing current members twice (hub + Country Table).
