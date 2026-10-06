Expectations

This exercise is intentionally designed to assess how you think, design, and build software in an AI‑driven environment. 

You are required to use AI tools to accelerate your work. We care about how you use them, the clarity of your thinking, and the quality of your engineering decisions.

We expect you to:

Demonstrate clarity in thought and structured problem solving
Show strong engineering fundamentals & product thinking
Make thoughtful architectural and design decisions
Write production‑quality code and tests
Use AI intentionally while maintaining correctness and quality
Please make incremental commits so we can understand how your solution evolved.

Technical Assessment: Deliverables

Create table queries – DDL for the raw/landing table, the staging table, and the country-specific target tables (e.g., in Snowflake).
Load the staging table with additional derived columns: Age (computed from DOB) and a Stale_Member flag where days since Flight_Date > 90.
Write the transformation logic (SQL and/or Python) to split members into their per-country target tables, applying the “latest record wins” rule when a member has moved countries.
Parse the semi-structured JSON redemption feed into a flattened, queryable table, and describe how you would join it back to the member profile data.
Create the necessary data validations — mandatory field checks, key-column uniqueness, and any checks you would add to catch the kind of data issues visible in the sample data above.
If we move forward with an interview, we would like to see a live demonstration.

