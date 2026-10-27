--Date: October 1,2026
--Intermediate — Aggregation, Subqueries, Window Functions, Anomaly Detection 
--Q.1: For each account, flag transactions where the amount is more than 3× that account's
--own average transaction amount.
select nameOrig,
       amount,
	   avg(amount) over(partition by nameOrig) as account_avg_amount,
	   case
	      when amount>3*AVG(amount) OVER (PARTITION BY nameOrig) then 'Flag'
		  else 'Normal'
		end as transaction_flag
from paysim;
--Q.2:Running total of CASH_OUT amount per account, ordered by step .
select nameOrig,
       step,
	   amount,
	   sum(amount) over (partition by nameOrig order by step rows between unbounded preceding and current row) as running_total_amount
from paysim
where type='CASH_OUT';
--Q.3: Find accounts making more than 5 transactions within the same step
select nameOrig,
       step,
	   count(*) as transaction_count
from paysim
group by  nameOrig,Step
having count(*) >5;
--Q.4: For each transaction, find how many steps passed since that account's previoustransaction;
--flag gaps under 2 steps as high-velocity.
with transaction_gaps as 
(select nameOrig,
       step,
	   lag(step,) over (partition by nameOrig order by step) as previous_step
from paysim
)
select nameOrig,
       step,
	   previous_step,
	   step - previous_step as step_gap,
	   case 
	      when step - previous_step < 2 then 'High Velocity'
		  else 'Normal'
	   end as velocity_flag
from transaction_gaps;
--5. Find the top 1% of transactions by amount, without hardcoding a dollar threshold
with ranked_transactions as
(select nameOrig,
       amount,
	   type,
	   isFraud,
	   percent_rank() over (order by amount) as percent_rank
from paysim)
select * from ranked_transactions
where percent_rank>0.99 and isFraud=1;
--6.Find transactions where the amount exceeds that account's own average — using a
--correlated subquery this time, not a window function
select p1.nameOrig,
       p1.type, 
	   p1.isFraud,
	   p1.amount 
from paysim p1
where p1.amount>(
select avg(p2.amount) from paysim p2 where p1.nameOrig=p2.nameOrig
);
--Another approach
WITH account_avg AS (
    SELECT
        nameOrig,
        AVG(amount) AS avg_amount
    FROM paysim
    GROUP BY nameOrig
)
SELECT
    p.nameOrig,
    p.type,
    p.isFraud,
    p.amount,
    a.avg_amount
FROM paysim p
JOIN account_avg a
    ON p.nameOrig = a.nameOrig
WHERE p.amount > a.avg_amount;
--Q.7:Detect structuring: accounts sending 3+ transactions each between 180,000
--199,999 (just under the flagging threshold) within a short window
with qualifying_transaction as
(select nameOrig,
       step,
	   amount,
	   type,
	   isFraud,
	   count(*) as qualifying_transactions
from paysim 
where amount>=180000 and amount < 200000),
transaction_gaps as
(
select nameOrig,
       step,
	   amount,
	   type,
	   isFraud,
	   lag(step) over (partition by namOrig order by step) as previous_steps
from qualifying_transactions
)
select nameOrig,
       step,
	   amount,
	   type,
	   isFraud,
	   previous_steps,
	   step - previous_steps as step_gap
from transaction_gaps;



--Q.8:.Fraud rate (share of transactions that are fraudulent) by transaction type. 
SELECT
    type,
    AVG(isFraud::numeric) AS fraud_rate
FROM paysim
GROUP BY type;
--Q.9:.Find transactions where the recorded balances don't reconcile: 
-- oldbalanceOrg - amount <> newbalanceOrig .
select nameOrig,
       type,
	   amount,
	   oldbalanceOrg,
	   newbalanceOrig,
	   isFraud
from paysim 
where oldbalanceOrg - amount <> newbalanceOrig;
--Date: 05/10/2026
--Q.10:For each account, return only its single largest transaction. 
with ranked_transactions as 
(
select nameOrig,
       amount,
	   type,
	   step, 
	   isFraud,
	   row_number() over (partition by nameOrig order by amount desc) as rnk_transaction
from paysim
)
select * from ranked_transactions
where rnk_transaction=1;
--11.Compute the average gap (in steps) between an account's consecutive transactions — a
--per-account "normal velocity" baseline. 
with transaction_velocity as
(
select nameOrig,
       step,
	   lag(step) over (partition by nameOrig Order By step) as previous_step
from paysim
)
select nameOrig,
       avg(step-previous_step) as Average_Step_Gap
from transaction_velocity
group by nameOrig;
--12. Find TRANSFER s immediately followed by a CASH_OUT from the same account,
--one step later — the canonical PaySim fraud chain.
with transaction_sequence as
(
select nameOrig,
       step,
	   type, 
	   amount,
	   lead(step) over (partition by nameOrig order by step) as next_step,
	   lead (type) over (partition by nameOrig Order by step) as next_type,
	   lead(amount) over (partition by nameOrig order by step) as next_amoiunt
from paysim
)
select * from transaction_sequence
where type= 'TRANSFER' and next_type = 'CASH_OUT' and  next_step=step+1;
--13.Compute a z-score for each transaction's amount relative to its own type, and return
--anything with |z| > 3.
with z_score_calculation as(
select amount,
       avg(amount) over (partition by type) as type_avg,
       stddev(amount) over (partition by type) as type_std
from paysim
)
select amount,
       (amount - type_avg)/type_std as z_score
from z_score_calculation
where abs((amount - type_avg)/type_std)>3;
--14. Find accounts with 3 or more transactions where amount > oldbalanceOrg :
--repeated attempts that should have failed on insufficient funds.
SELECT
    nameOrig,
    COUNT(*) AS insufficient_funds_attempts
FROM paysim
WHERE amount > oldbalanceOrg
GROUP BY nameOrig
HAVING COUNT(*) >= 3
ORDER BY insufficient_funds_attempts DESC;
--15.Using a CTE, isolate WHERE amount > TRANSFER s over 100,000, 
--then find which of those destinationaccounts went on to CASH_OUT .
WITH large_transfers AS
(
    SELECT
        nameOrig,
        nameDest,
        step,
        amount
    FROM paysim
    WHERE type = 'TRANSFER'
      AND amount > 100000
)
SELECT
    l.nameOrig AS transfer_sender,
    l.nameDest AS destination_account,
    l.step AS transfer_step,
    l.amount AS transfer_amount,
    p.step AS cashout_step,
    p.amount AS cashout_amount
FROM large_transfers l
JOIN paysim p
    ON l.nameDest = p.nameOrig
WHERE p.type = 'CASH_OUT'
  AND p.step > l.step
ORDER BY l.step, p.step;
--16. For each step , what share of transactions are CASH_OUT vs. everything else? 
select step,
       count(*) as total_transactions,
	   sum (case when type='CASH_OUT' then 1 else 0 end) as cashout_transactions,
	   sum (case when type='CASH_OUT' then 1 else 0 end)/ count(*) as cashou_share
from paysim
group by step;
--17. Median transaction amount per type
select type,
       percentile_cont(0.5) within group (order by amount) as meadian_amount
from paysim
group by type;
/*18. Debugging:Fix this — meant to show each account alongside its average transaction amount:
SELECT nameOrig, amount, AVG(amount)
FROM transactions
GROUP BY nameOrig;*/
select nameOrig,
       amount,
	   avg(amount) over (partition by nameOrig ) as average_transaction_amount
from paysim;
/*
19.Debugging: Fix this - meant to flag accounts with more than 10 transactions:
SELECT nameOrig, COUNT(*) AS txn_count
FROM transactions
WHERE COUNT(*) > 10
GROUP BY nameOrig
*/
select nameOrig,
       count(*) as txn_count
from paysim
group by nameOrig
having count(*)>3;
/*20.Debugging: This is meant to rank each account's transactions by amount, but every
row comes back ranked 1:
SELECT nameOrig, amount,
RANK() OVER (PARTITION BY nameOrig) AS amt_rank
FROM transactions;
*/
SELECT nameOrig, 
       amount,
       RANK() OVER (PARTITION BY nameOrig order by amount) AS amt_rank
FROM paysim;
--Date: 07/10/2026
--LEVEL: Advanced - Fraud Chains, Multi-Signal Risk, Scale
--21.Using a recursive CTE, trace transaction chains up to 3 hops (A→B→C): an account
--receives, then forwards.
WITH RECURSIVE chain AS 
(SELECT nameOrig AS origin,
        nameDest AS current_account,
        step AS last_step,
        amount AS last_amount,
        ARRAY[nameOrig, nameDest]::VARCHAR[]  AS path,
        1 AS depth
FROM paysim
UNION ALL
SELECT
        c.origin,
        t.nameDest,
        t.step,
        t.amount,
        c.path || t.nameDest,
        c.depth + 1
FROM chain c
JOIN paysim t ON t.nameOrig = c.current_account  AND t.step >= c.last_step            
WHERE c.depth < 3 AND NOT t.nameDest = ANY(c.path)    
)
SELECT
    origin,
    path,
    depth,
    last_amount
FROM chain
WHERE depth >= 2                          
ORDER BY depth DESC, origin;
--22.Identify possible mule accounts: high fan-in (many distinct senders) followed by a
--fast, near-total cash-out.
WITH fan_in AS 
(
-- Customer accounts receiving TRANSFERs from several distinct senders
SELECT nameDest AS account,
        COUNT(DISTINCT nameOrig) AS distinct_senders,
        COUNT(*) AS inbound_txns,
        SUM(amount) AS total_received,
        MIN(step) AS first_in_step,
        MAX(step) AS last_in_step
FROM paysim
WHERE type = 'TRANSFER'
AND nameDest LIKE 'C%'                
GROUP BY nameDest
HAVING COUNT(DISTINCT nameOrig) >= 3     
),
fast_cash_out AS 
(
 -- CASH_OUTs by those accounts, from first receipt to 3 steps after the last
SELECT  f.account,
        SUM(o.amount) AS total_cashed_out,
        MIN(o.step) - f.last_in_step AS steps_after_last_in,
        MAX(o.isFraud) AS cashout_flagged_fraud
FROM fan_in f
JOIN paysim o ON o.nameOrig = f.account AND o.type = 'CASH_OUT' AND o.step BETWEEN f.first_in_step 
     AND f.last_in_step + 3
GROUP BY f.account, f.last_in_step
)
SELECT
    f.account,
    f.distinct_senders,
    f.inbound_txns,
    f.total_received,
    c.total_cashed_out,
    ROUND(c.total_cashed_out / f.total_received, 2) AS cashout_ratio,
    c.steps_after_last_in,
    c.cashout_flagged_fraud
FROM fan_in f
JOIN fast_cash_out c USING (account)
WHERE c.total_cashed_out >= 0.9 * f.total_received   
ORDER BY f.distinct_senders DESC, f.total_received DESC;
--23.Flag accounts with 3+ over-limit attempts (amount > oldbalanceOrg ) inside any
--rolling 24-step window.
with over_limit_txn as(
select nameOrig,
       step,
	   amount,
	   oldbalanceOrg
from paysim
where amount > oldbalanceOrg
),
rolling_counts as
(select nameOrig,
       step,
       count(*) over (partition by nameOrig order by step 
	                  range between 24 preceding and current row ) as rolling_count
from over_limit_txn
)
select nameOrig,
       step,
	   rolling_count
from rolling_counts
where rolling_count>=3;
--24.Identify high-risk merchants: destinations that receive disproportionately often
--from accounts with a fraud history, even though the merchant itself is never isFraud = 1 
-- Identify high-risk destination accounts
WITH fraud_history_senders AS (
    SELECT DISTINCT nameOrig
    FROM paysim
    WHERE isFraud = 1
),

fraud_history_exposure AS (
    SELECT
        p.nameDest AS destination_account,
        COUNT(*) AS suspicious_transaction_count,
        COUNT(DISTINCT f.nameOrig) AS distinct_fraud_history_senders,
        SUM(p.amount) AS suspicious_incoming_amount
    FROM paysim p
    JOIN fraud_history_senders f
        ON p.nameOrig = f.nameOrig
    GROUP BY p.nameDest
),

total_incoming AS (
    SELECT
        nameDest AS destination_account,
        COUNT(*) AS total_incoming_transactions,
        SUM(amount) AS total_incoming_amount
    FROM paysim
    GROUP BY nameDest
),

fraud_labelled_destinations AS (
    SELECT DISTINCT nameOrig AS destination_account
    FROM paysim
    WHERE isFraud = 1
)

SELECT
    f.destination_account,
    f.suspicious_transaction_count,
    f.distinct_fraud_history_senders,
    f.suspicious_incoming_amount,
    t.total_incoming_transactions,
    t.total_incoming_amount,

    ROUND(
        100.0 * f.suspicious_transaction_count
        / NULLIF(t.total_incoming_transactions, 0),
        2
    ) AS suspicious_exposure_percentage

FROM fraud_history_exposure f
JOIN total_incoming t
    ON f.destination_account = t.destination_account

WHERE NOT EXISTS (
    SELECT 1
    FROM fraud_labelled_destinations d
    WHERE d.destination_account = f.destination_account
)

ORDER BY
    suspicious_exposure_percentage DESC,
    f.distinct_fraud_history_senders DESC;
--25. For each account, compute a running average and running max of transaction amount
--up to and including the current one (ordered by step ) — "how does this compare to what
--I've seen from this account so far," which is the shape real-time scoring actually needs.
select nameOrig,
       step,
	   amount,
	   avg(amount) over (partition by nameOrig order by step 
	                    rows between unbounded preceding and current row) as running_avg_amount,
	   max(amount) over (partition by nameOrig order by step 
	                     rows between unbounded preceding and current row) as running_max_amount
from paysim;
--26. Detect a structuring ring: 3+ distinct origin accounts all paying 
-- the same destination, each just under 200,000, within a tight step window.
SELECT
    nameDest,
    FLOOR(step / 24.0) AS step_bucket,
    COUNT(DISTINCT nameOrig) AS distinct_sender_accounts,
    COUNT(*) AS qualifying_transaction_count,
    SUM(amount) AS total_transaction_amount
FROM paysim
WHERE amount BETWEEN 150000 AND 199999
GROUP BY
    nameDest,
    FLOOR(step / 24.0)
HAVING COUNT(DISTINCT nameOrig) >= 3
ORDER BY
    distinct_sender_accounts DESC,
    qualifying_transaction_count DESC;
--27.Write a single-pass query — no correlated subquery — that returns every account's
-- transaction count, total amount, and fraud rate. It needs to hold up on 100M+ rows.
select
      nameOrig,
	  count(*) as transaction_count,
	  sum(amount) as total_amount,
	  avg(isFraud::numeric) as fraud_rate
from paysim
group by nameOrig;
--28. Find the longest transaction chain in the dataset using a recursive CTE with a cycle guard.
WITH RECURSIVE chain AS 
(
-- Base case: every money-moving transaction starts a 1-hop chain
 SELECT
        nameOrig AS origin,
        nameDest AS current_account,
        step AS last_step,
        ARRAY[nameOrig, nameDest]::varchar[] AS path,       
        1 AS depth    
FROM paysim
WHERE type IN ('TRANSFER', 'CASH_OUT')
UNION ALL
-- Recursive case: the receiver forwards the money onward
SELECT
        c.origin,
        t.nameDest,
        t.step,
        c.path || t.nameDest,
        c.depth + 1
    FROM chain c
    JOIN paysim t
      ON t.nameOrig = c.current_account
     AND t.step >= c.last_step                    
     AND t.type IN ('TRANSFER', 'CASH_OUT')
    WHERE NOT t.nameDest = ANY(c.path)             
      AND c.depth < 10                             
)
SELECT
    origin,
    path,
    depth
FROM chain
WHERE depth = (SELECT MAX(depth) FROM chain)      
ORDER BY origin;
--Date: 17/10/2026
--29.Build a composite risk score per transaction from amount z-score, account velocity,
-- and destination type (merchant vs. customer), then return the top 100.
with account_stats as
(
select nameOrig,
       nameDest,
	   step,
	   type,
	   amount,
	   avg(amount)over (partition by nameOrig ) as mean_amount,
	   stddev_pop(amount) over(partition by nameOrig) as sd_amount
from paysim
),
z_score as
(
select *,
       (amount - mean_amount)/nullif(sd_amount,0) as z_score_val
from account_stats
),
account_velocity as 
(
select *,
       count(*) over (partition by nameOrig order by step
	                  range between 24 preceding and current row) as account_velocity_val
from z_score
),
destination_type as
(select *,
        null::numeric as destination_type_risk
from account_velocity
),
normalized_score as(
SELECT
        *,
        -- Normalize positive amount anomalies to [0, 1]
        CASE
            WHEN z_score_val IS NULL THEN NULL
            ELSE GREATEST(0, LEAST(z_score_val / 5.0, 1))
        END AS normalized_amount_risk,

        -- Illustrative velocity normalization
        LEAST(account_velocity_val / 10.0, 1) AS normalized_velocity_risk
from destination_type)
--final result
select nameOrig,
       nameDest,
	   step,
	   type,
	   amount,
	   account_velocity_val,
	   z_score_val,
	   0.625*normalized_amount_risk+0.375*normalized_velocity_risk as risk_score
from normalized_score
order by risk_score desc limit 100;
--30.Find accounts that go dormant for 500+ steps and then suddenly transact heavily
--a classic account-takeover signature.
with dormancy_analysis as
(SELECT
    nameOrig,
    step,
    amount,
    LAG(step) OVER (
        PARTITION BY nameOrig
        ORDER BY step
    ) AS previous_step
FROM paysim
),
dormant_account as
(select nameOrig,
       amount,
	   step as return_step,
	   previous_step,
	   step - previous_step as step_gap
from dormancy_analysis
WHERE previous_step IS NOT NULL AND (step - previous_step) > 500
);
-- 31. Find account pairs that repeatedly transact back and forth
-- (A → B, then B → A) within short step windows — possible layering.
WITH reverse_transactions AS
(
SELECT
        t1.nameOrig,
        t1.nameDest,
        t1.step,
        t1.amount,
		LEAST(t1.nameOrig, t1.nameDest) AS account_1,
        GREATEST(t1.nameOrig, t1.nameDest) AS account_2,
		t2.step - t1.step AS step_gap

FROM paysim t1
INNER JOIN paysim t2 ON t1.nameOrig = t2.nameDest AND t1.nameDest = t2.nameOrig
WHERE t1.nameOrig <> t1.nameDest AND t2.step > t1.step AND t2.step - t1.step <= 10
)
SELECT
    account_1,
    account_2,

    COUNT(*) AS reverse_transaction_matches,
    AVG(step_gap) AS avg_step_gap,
    MIN(step_gap) AS min_step_gap,
    MAX(step_gap) AS max_step_gap

FROM reverse_transactions

GROUP BY
    account_1,
    account_2

HAVING COUNT(*) > 1

ORDER BY
    reverse_transaction_matches DESC,
    avg_step_gap ASC;
/*32.Debugging.This is meant to be a fast lookup on CASH_OUT transactions but runs a
full table scan even with an index on type :
sql
SELECT * FROM transactions WHERE UPPER(type) = 'CASH_OUT';
*/
EXPLAIN ANALYZE
SELECT *
FROM paysim
WHERE type = 'CASH_OUT';
EXPLAIN ANALYZE
SELECT *
FROM paysim
WHERE UPPER(type) = 'CASH_OUT';

--33. Incremental nightly fraud scoring
-- Q53: Process only new transactions in a nightly batch job

WITH new_transactions AS
(
    SELECT *
    FROM paysim
    WHERE step >
    (
        SELECT COALESCE(MAX(last_processed_step), 0)
        FROM last_batch_log
    )
)

SELECT
    step,
    type,
    nameOrig,
    nameDest,
    amount,
    isFraud,

    CASE
        WHEN amount >= 200000 AND type = 'TRANSFER'
            THEN 'HIGH_RISK'

        WHEN amount >= 100000 AND type = 'CASH_OUT'
            THEN 'MEDIUM_RISK'

        ELSE 'NORMAL'
    END AS risk_category

FROM new_transactions
ORDER BY step;
--34.Compare isFlaggedFraud against isFraud: how many transactions did the flat
-->200,000 rule miss, and how many did it flag that weren't actually fraud?
with conf_matrix as 
(
select
      count(*) as total_transactions,
	  --true positives
	  count(*) filter(where amount > 200000 and isFraud=1) as true_positive,
	  --true negative
	  count(*) filter(where amount <= 200000 and isFraud=0) as true_negative,
	  --false positve
	  count(*) filter (where amount > 200000 and isFraud=0) as false_positive,
	  --false negative
	  count(*) filter (where amount <= 200000 and isFraud=1) as false_negative
from paysim
)
select true_positive,
       false_positive,
	   false_negative,
	   round(100.0*true_positive/nullif(true_positive+false_positive,0),2) as precision,
       round(100.0*true_positive/nullif(true_positive+false_negative,0),2) as recall
from conf_matrix;
--35.For each account with at least one fraudulent transaction, find the gap (in steps)
-- between its very first transaction and its first fraudulent one.
select 
      nameOrig,
	  min(step) as first_transaction_step,
	  min(step) filter (where isFraud=1) as first_fraud_transaction_step,
	  min(step) filter (where isFraud=1) - min(step) as fraud_step_gap
from paysim 
group by nameOrig
having  COUNT(*) FILTER (WHERE isFraud = 1) > 0
order by fraud_step_gap;
/*36.Debugging: Meant to find merchants receiving from many distinct fraud-linked
accounts — errors out, and the approach is wrong even fixed naively:
sql:
SELECT nameDest, COUNT(*)
FROM paysim t1, paysim t2
WHERE t1.nameOrig = t2.nameOrig
AND t1.isFraud = 1
GROUP BY nameDest;
*/
SELECT
      nameDest AS merchant,
      count(distinct nameOrig) AS distinct_fraud_accounts
FROM paysim
WHERE isFraud=1
GROUP BY nameDest
HAVING count(distinct nameOrig)>3 
ORDER BY distinct_fraud_accounts DESC;

/*37.Debugging:This recursive CTE for tracing transaction chains never finishes:
sql
WITH RECURSIVE chain AS (
SELECT nameOrig, nameDest, amount, 1 AS depth
FROM paysim
UNION ALL
SELECT c.nameOrig, t.nameDest, t.amount, c.depth + 1
FROM chain c
JOIN transactions t ON c.nameDest = t.nameOrig
)
SELECT * FROM chain
*/
WITH RECURSIVE chain AS
(
    -- Anchor: first transaction
    SELECT
        nameOrig,
        nameDest,
        amount,
        1 AS depth,
        ARRAY[nameOrig, nameDest]::VARCHAR[] AS path
    FROM paysim

    UNION ALL

    -- Recursive: find the next transaction
    SELECT
        c.nameOrig,
        t.nameDest,
        t.amount,
        c.depth + 1 AS depth,
        c.path || t.nameDest
    FROM chain c
    JOIN paysim t
        ON c.nameDest = t.nameOrig
    WHERE NOT (t.nameDest = ANY(c.path))
      AND c.depth < 10
)

SELECT
    nameOrig AS starting_account,
    nameDest AS current_account,
    amount,
    depth,
    path
FROM chain
ORDER BY starting_account, depth;
/*38.Debugging: Meant to return the top 3 accounts with more than 3 over-limit
attempts — comes back completely empty even though qualifying accounts exist:
sql
SELECT nameOrig, COUNT(*)
FROM paysim
WHERE amount > oldbalanceOrg
GROUP BY nameOrig
HAVING COUNT(*) > 3
ORDER BY COUNT(*) DESC
LIMIT 3
OFFSET 5;
*/
SELECT
    nameOrig,
    COUNT(*) AS over_limit_attempts
FROM paysim
WHERE amount > oldbalanceOrg
GROUP BY nameOrig
HAVING COUNT(*) > 3
ORDER BY over_limit_attempts DESC
LIMIT 3;
/*39.Debugging: This 3-transaction rolling average, meant for a real-time scoring
pipeline, leaks future data:
sql
SELECT nameOrig, step, amount,
AVG(amount) OVER (
PARTITION BY nameOrig ORDER BY step
ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING) AS rolling_avg
FROM paysim;
*/
SELECT
    nameOrig,
    step,
    amount,
    AVG(amount) OVER (
        PARTITION BY nameOrig
        ORDER BY step
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS rolling_avg
FROM transactions;
/*40.

*/
WITH account_input AS (
    SELECT 'C840083671'::VARCHAR(50) AS account_id
),

-- 1. Collect every transaction involving the account
account_transactions AS (
    SELECT p.*
    FROM paysim p
    CROSS JOIN account_input a
    WHERE p.nameOrig = a.account_id
       OR p.nameDest = a.account_id
),

-- 2. Calculate account-level statistics
account_stats AS (
    SELECT
        COUNT(*) AS total_transactions,
        COALESCE(SUM(amount), 0) AS total_transaction_volume,
        COALESCE(AVG(amount), 0) AS average_transaction_amount,

        COUNT(*) FILTER (
            WHERE isFraud = 1
        ) AS fraud_transaction_count,

        COUNT(*) FILTER (
            WHERE isFlaggedFraud = 1
        ) AS flagged_transaction_count,

        COUNT(DISTINCT type) AS transaction_types_used,

        MIN(step) AS first_active_step,
        MAX(step) AS last_active_step

    FROM account_transactions
),

-- 3. Find the largest transaction
largest_transaction AS (
    SELECT
        step,
        type,
        nameOrig,
        nameDest,
        amount,
        oldbalanceOrg,
        newbalanceOrig,
        oldbalanceDest,
        newbalanceDest,
        isFraud,
        isFlaggedFraud
    FROM account_transactions
    ORDER BY amount DESC, step ASC
    LIMIT 1
),

-- 4. Collect fraud-flag history
fraud_history AS (
    SELECT
        COUNT(*) AS fraud_event_count,

        JSONB_AGG(
            JSONB_BUILD_OBJECT(
                'step', step,
                'type', type,
                'sender', nameOrig,
                'receiver', nameDest,
                'amount', amount,
                'isFraud', isFraud,
                'isFlaggedFraud', isFlaggedFraud
            )
            ORDER BY step
        ) AS fraud_events

    FROM account_transactions
    WHERE isFraud = 1
       OR isFlaggedFraud = 1
),

-- 5. Detect TRANSFER -> CASH_OUT chains
transfer_cashout_chains AS (
    SELECT
        t1.nameOrig AS transfer_sender,
        t1.nameDest AS intermediate_account,
        t1.step AS transfer_step,
        t1.amount AS transfer_amount,
        t1.isFraud AS transfer_is_fraud,

        t2.nameDest AS cashout_receiver,
        t2.step AS cashout_step,
        t2.amount AS cashout_amount,
        t2.isFraud AS cashout_is_fraud,

        t2.step - t1.step AS step_gap,

        CASE
            WHEN t1.nameOrig = a.account_id
                THEN 'TRANSFER_SENDER'
            WHEN t1.nameDest = a.account_id
                THEN 'INTERMEDIATE_ACCOUNT'
            WHEN t2.nameDest = a.account_id
                THEN 'CASHOUT_RECEIVER'
        END AS account_role

    FROM paysim t1
    INNER JOIN paysim t2
        ON t1.nameDest = t2.nameOrig

    CROSS JOIN account_input a

    WHERE t1.type = 'TRANSFER'
      AND t2.type = 'CASH_OUT'
      AND t2.step > t1.step

      AND (
          t1.nameOrig = a.account_id
          OR t1.nameDest = a.account_id
          OR t2.nameDest = a.account_id
      )
),

-- 6. Summarise transaction-chain evidence
chain_summary AS (
    SELECT
        COUNT(*) AS chain_count,

        JSONB_AGG(
            JSONB_BUILD_OBJECT(
                'account_role', account_role,
                'transfer_sender', transfer_sender,
                'intermediate_account', intermediate_account,
                'transfer_step', transfer_step,
                'transfer_amount', transfer_amount,
                'transfer_is_fraud', transfer_is_fraud,
                'cashout_receiver', cashout_receiver,
                'cashout_step', cashout_step,
                'cashout_amount', cashout_amount,
                'cashout_is_fraud', cashout_is_fraud,
                'step_gap', step_gap
            )
            ORDER BY transfer_step
        ) AS chain_evidence

    FROM transfer_cashout_chains
)

-- 7. Assemble the final investigator case file
SELECT
    a.account_id,

    -- Account activity
    s.total_transactions,
    s.total_transaction_volume,
    s.average_transaction_amount,
    s.transaction_types_used,
    s.first_active_step,
    s.last_active_step,

    -- Largest transaction
    lt.amount AS largest_transaction_amount,
    lt.type AS largest_transaction_type,
    lt.step AS largest_transaction_step,
    lt.nameOrig AS largest_transaction_sender,
    lt.nameDest AS largest_transaction_receiver,

    -- Largest transaction balance details
    lt.oldbalanceOrg,
    lt.newbalanceOrig,
    lt.oldbalanceDest,
    lt.newbalanceDest,

    -- Fraud history
    s.fraud_transaction_count,
    s.flagged_transaction_count,
    fh.fraud_event_count,

    COALESCE(
        fh.fraud_events,
        '[]'::JSONB
    ) AS fraud_history,

    -- Transfer -> Cash-out evidence
    cs.chain_count,

    COALESCE(
        cs.chain_evidence,
        '[]'::JSONB
    ) AS transfer_cashout_evidence

FROM account_input a
CROSS JOIN account_stats s
CROSS JOIN fraud_history fh
CROSS JOIN chain_summary cs
LEFT JOIN largest_transaction lt
    ON TRUE;