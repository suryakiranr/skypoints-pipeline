# Physical per-country tables, generated from the Country Reference

The brief asks for one table per country (`Table_India`, …). At billions of rows a day, a single table clustered by country with a view per country would be cheaper to operate. We still build real Country Tables to meet the brief. Their DDL and MERGE statements are generated from the Country Reference, so adding a country means adding a reference row, not writing code.

## Considered Options

- **One clustered table + per-country views**: one MERGE, no per-country fan-out cost. Rejected only because it departs from the stated requirement; it is the first thing to revisit if the per-country write cost becomes a problem.
