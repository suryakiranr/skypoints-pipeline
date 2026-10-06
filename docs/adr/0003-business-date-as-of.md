# Age and Stale Member are computed as of the file's Business Date

The brief says "days since Flight_Date > 90", which reads naturally as days since today. We use the Business Date from the file name instead. With CURRENT_DATE, reloading a past file would give different results, tests could not be deterministic, and every 2012-dated sample member would come out stale. Anyone who needs "stale as of today" can compute it at query time from Last Flight Date.
