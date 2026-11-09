/* =====================================================================
   PANEL PREDIKSI REPEAT-ORDER — versi TERBACA (gaya join-tanggal).
   Window fitur = [target-9bln .. target-1bln]. Label IsBuy = beli di bulan target.
   Recency basis t-1. Produksi (OnTime/DemandFG/MaxDaysLate) di-bucket by done_month.
   Exclude Shipping/All/Jasa/Jasa Design + Proofing; Label DIINCLUDE. state='sale'.
   Keep freq>=1. Non-string NULL -> -1. (UTMSource sengaja tidak dipakai.)

   FITUR KELOMPOK A (order-time, berbasis SUB-TOTAL):
   - Monetary         = total nilai subtotal
   - MeanOrderValue   = rata-rata nilai subtotal per-SO (= Monetary/Freq)
   - MedianOrderValue = median nilai subtotal per-SO
   - MaxOrderValue    = nilai subtotal SO terbesar
   ===================================================================== */

WITH lines AS (
    SELECT
        sale_order_partner_id                                   AS cust_id,
        sale_order_id,
        sale_order_date_order_actual                            AS order_ts,
        date_trunc('month', sale_order_date_order_actual)::date AS order_month,
        first_date_finished_done                                AS done_ts,
        date_trunc('month', first_date_finished_done)::date     AS done_month,
        first_earliest_production_deadline                      AS deadline_ts,
        (product_category_name = 'Proofing')                                AS is_proofing_cat,
        (product_category_name IN ('Shipping','All','Jasa','Jasa Design'))  AS is_excluded_cat,
        sale_order_line_price_subtotal                          AS line_sub,
        sale_order_line_discount_from_pricelist                 AS disc,
        first_demand_qty, first_fg_qty, on_time_production,
        (product_template_custom_product = 'custom')            AS is_custom,
        is_flexo, product_template_is_roll                      AS is_roll,
        sale_order_is_returning_customer                        AS is_returning,
        is_priority_customer                                    AS is_priority,
        account_payment_term_name,
        product_category_name,
        sale_order_line_product_id,
        CASE
            WHEN product_material_category_name IS NULL THEN 'Other'
            WHEN product_material_category_name ILIKE '%Lid%' THEN product_material_category_name 
            WHEN upper(product_material_category_name) LIKE 'PET%'            THEN 'PET'   
            WHEN upper(product_material_category_name) LIKE 'MET%'            THEN 'MET'
            WHEN upper(product_material_category_name) LIKE 'OPP%'            THEN 'OPP'
            WHEN upper(product_material_category_name) LIKE 'NY%'             THEN 'NY'    
            WHEN upper(product_material_category_name) LIKE 'ALU%'            THEN 'ALU'
            WHEN upper(product_material_category_name) LIKE 'DPE%'            THEN 'DPE'
            WHEN upper(product_material_category_name) LIKE 'RCPP%'           THEN 'RCPP'
            WHEN upper(product_material_category_name) LIKE 'PCP%'            THEN 'PCP'   
            WHEN upper(product_material_category_name) LIKE 'FOOPAC%'         THEN 'Foopack'
            WHEN upper(product_material_category_name) LIKE 'PAPER SEMICOAT%' THEN 'Paper Semicoat'
            WHEN upper(product_material_category_name) LIKE 'PP%'             THEN 'PP'    
            WHEN upper(product_material_category_name) LIKE 'PE%'             THEN 'PE'    
            ELSE 'Other'
        END                                                     AS mat_family
    FROM public.rpt_sps_sales_flats
    WHERE COALESCE(sale_order_is_partial_parent, false) = false
      AND sale_order_state = 'sale'
),
purchases  AS (SELECT * FROM lines     WHERE NOT is_excluded_cat AND NOT is_proofing_cat),
proofing   AS (SELECT * FROM lines     WHERE is_proofing_cat),
production AS (SELECT * FROM purchases  WHERE done_month IS NOT NULL),

bounds  AS (SELECT min(order_month) AS first_month, max(order_month) AS last_month FROM lines),
targets AS (
    SELECT generate_series(
             (SELECT first_month + interval '9 month' FROM bounds),
             (SELECT last_month  + interval '1 month'              FROM bounds),
             interval '1 month')::date AS target_month
),
customers AS (SELECT DISTINCT cust_id FROM lines),
base      AS (SELECT c.cust_id, t.target_month FROM customers c CROSS JOIN targets t),

agg_order AS (
    SELECT b.cust_id, b.target_month,
        count(DISTINCT p.sale_order_id)                        AS freq,
        count(DISTINCT p.sale_order_line_product_id)           AS n_products,
        sum(p.line_sub)                                        AS monetary,
        sum(p.line_sub)                                        AS revenue,
        COALESCE(sum(p.line_sub) FILTER (WHERE p.is_custom),0) AS rev_custom,
        COALESCE(sum(p.line_sub) FILTER (WHERE p.is_flexo),0)  AS rev_flexo,
        COALESCE(sum(p.line_sub) FILTER (WHERE p.is_roll),0)   AS rev_roll,
        sum(p.disc * p.line_sub)                               AS disc_wsum,
        min(p.order_month)                                     AS first_purchase,
        max(p.order_month)                                     AS last_purchase,
        bool_or(p.order_month = b.target_month - interval '1 month')::int AS last_1,
        bool_or(p.order_month = b.target_month - interval '2 month')::int AS last_2,
        bool_or(p.order_month = b.target_month - interval '3 month')::int AS last_3,
        bool_or(p.order_month = b.target_month - interval '4 month')::int AS last_4,
        bool_or(p.order_month = b.target_month - interval '5 month')::int AS last_5,
        bool_or(p.order_month = b.target_month - interval '6 month')::int AS last_6,
        bool_or(p.order_month = b.target_month - interval '7 month')::int AS last_7,
        bool_or(p.order_month = b.target_month - interval '8 month')::int AS last_8,
        bool_or(p.order_month = b.target_month - interval '9 month')::int AS last_9,
        count(p.sale_order_id)                                                 AS n_lines,
        count(*) FILTER (WHERE p.product_category_name = 'Paper Cup')             AS n_paper_cup,
        count(*) FILTER (WHERE p.product_category_name = 'Lid')                   AS n_lid,
        count(*) FILTER (WHERE p.product_category_name = 'Standing Pouch')        AS n_standing_pouch,
        count(*) FILTER (WHERE p.product_category_name = 'Custom Roll')           AS n_custom_roll,
        count(*) FILTER (WHERE p.product_category_name = 'Gusset')                AS n_gusset,
        count(*) FILTER (WHERE p.product_category_name = 'Roll Lid Cup')          AS n_roll_lid_cup,
        count(*) FILTER (WHERE p.product_category_name = '3 Side Seal (Sachet)')  AS n_3side,
        count(*) FILTER (WHERE p.product_category_name = 'Center Seal')           AS n_center_seal,
        count(*) FILTER (WHERE p.product_category_name = 'Label')                 AS n_label,
        count(*) FILTER (WHERE p.mat_family = 'PET')                 AS mm_pet,
        count(*) FILTER (WHERE p.mat_family = 'MET')                 AS mm_met,
        count(*) FILTER (WHERE p.mat_family = 'OPP')                 AS mm_opp,
        count(*) FILTER (WHERE p.mat_family = 'NY')                  AS mm_ny,
        count(*) FILTER (WHERE p.mat_family = 'ALU')                 AS mm_alu,
        count(*) FILTER (WHERE p.mat_family = 'DPE')                 AS mm_dpe,
        count(*) FILTER (WHERE p.mat_family = 'PCP')                 AS mm_pcp,
        count(*) FILTER (WHERE p.mat_family = 'RCPP')                AS mm_rcpp,
        count(*) FILTER (WHERE p.mat_family = 'Foopack')             AS mm_foopack,
        count(*) FILTER (WHERE p.mat_family = 'Paper Semicoat')      AS mm_papersemicoat,
        count(*) FILTER (WHERE p.mat_family = 'PP')                  AS mm_pp,
        count(*) FILTER (WHERE p.mat_family = 'PE')                  AS mm_pe,
        count(*) FILTER (WHERE p.mat_family = 'Plastic Lid')         AS mm_plasticlid,
        count(*) FILTER (WHERE p.mat_family = 'Bio Lid')             AS mm_biolid,
        count(*) FILTER (WHERE p.mat_family = 'Bagasse Lid')         AS mm_bagasselid,
        count(*) FILTER (WHERE p.mat_family = 'PP Lid')              AS mm_pplid,
        count(*) FILTER (WHERE p.mat_family = 'PET Transparent Lid') AS mm_pettranslid,
        count(*) FILTER (WHERE p.mat_family = 'Other')               AS mm_other
    FROM base b
    LEFT JOIN purchases p
      ON p.cust_id = b.cust_id
     AND p.order_month >= b.target_month - interval '9 month'
     AND p.order_month <  b.target_month
    GROUP BY b.cust_id, b.target_month
),
/* ---- KELOMPOK A: statistik nilai per-SO (berbasis SUB-TOTAL) ---- */
so_values AS (
    SELECT b.cust_id, b.target_month, p.sale_order_id, p.order_ts,
        sum(p.line_sub) AS so_value            
    FROM base b JOIN purchases p
      ON p.cust_id = b.cust_id
     AND p.order_month >= b.target_month - interval '9 month'
     AND p.order_month <  b.target_month
    GROUP BY b.cust_id, b.target_month, p.sale_order_id, p.order_ts
),
agg_value AS (
    SELECT cust_id, target_month,
        avg(so_value)                                                         AS mean_order,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY so_value)                 AS median_order,
        max(so_value)                                                         AS max_order,
        SUM(so_value)/COUNT(DISTINCT DATE_TRUNC('month', order_ts))           AS value_per_order_month
    FROM so_values GROUP BY cust_id, target_month
),
agg_prod AS (
    SELECT b.cust_id, b.target_month,
        sum(pr.first_fg_qty)         AS fg,
        sum(pr.first_demand_qty)     AS demand,
        sum(pr.on_time_production)   AS ontime_sum,
        count(pr.on_time_production) AS ontime_cnt,
        max(pr.done_ts::date - pr.deadline_ts::date)::int AS max_days_late
    FROM base b
    LEFT JOIN production pr
      ON pr.cust_id = b.cust_id
     AND pr.done_month >= b.target_month - interval '9 month'
     AND pr.done_month <  b.target_month
    GROUP BY b.cust_id, b.target_month
),
agg_proof AS (
    SELECT b.cust_id, b.target_month,
        count(DISTINCT pf.sale_order_id) AS proof_count,
        max(pf.order_month)              AS last_proof
    FROM base b
    LEFT JOIN proofing pf
      ON pf.cust_id = b.cust_id
     AND pf.order_month >= b.target_month - interval '9 month'
     AND pf.order_month <  b.target_month
    GROUP BY b.cust_id, b.target_month
),
purchase_months AS (
    SELECT DISTINCT b.cust_id, b.target_month, p.order_month AS pmonth
    FROM base b JOIN purchases p
      ON p.cust_id = b.cust_id
     AND p.order_month >= b.target_month - interval '9 month'
     AND p.order_month <  b.target_month
),
/* ---- jeda antar-pembelian: Hanya MAX ---- */
agg_gap AS (
    SELECT cust_id, target_month,
        max(gap_months)::int    AS max_gap
    FROM (
        SELECT cust_id, target_month,
            (EXTRACT(YEAR FROM pmonth)-EXTRACT(YEAR FROM prev))*12
          + (EXTRACT(MONTH FROM pmonth)-EXTRACT(MONTH FROM prev)) AS gap_months
        FROM (
            SELECT cust_id, target_month, pmonth,
                lag(pmonth) OVER (PARTITION BY cust_id, target_month ORDER BY pmonth) AS prev
            FROM purchase_months
        ) s WHERE prev IS NOT NULL
    ) g
    GROUP BY cust_id, target_month
),
agg_attr AS (
    SELECT DISTINCT ON (b.cust_id, b.target_month)
        b.cust_id, b.target_month, p.is_returning, p.is_priority, p.account_payment_term_name
    FROM base b JOIN purchases p
      ON p.cust_id = b.cust_id
     AND p.order_month >= b.target_month - interval '9 month'
     AND p.order_month <  b.target_month
    ORDER BY b.cust_id, b.target_month, p.order_ts DESC NULLS LAST
),
label AS (
    SELECT b.cust_id, b.target_month, 
        CASE 
            -- Jika target_month berada di bulan ini atau masa depan, jadikan NULL
            WHEN b.target_month >= date_trunc('month', CURRENT_DATE)::date THEN NULL
            -- Jika bulan sudah lewat, set 1 (beli) atau 0 (tidak beli)
            ELSE (count(p.sale_order_id) > 0)::int 
        END AS is_buy
    FROM base b LEFT JOIN purchases p
      ON p.cust_id = b.cust_id AND p.order_month = b.target_month
    GROUP BY b.cust_id, b.target_month
)
SELECT
    to_char(o.target_month, 'MM-YYYY')                                    AS "Date",
    o.cust_id                                                             AS "CustID",
    ( (EXTRACT(YEAR FROM o.target_month)-EXTRACT(YEAR FROM (SELECT first_month FROM bounds)))*12
    + (EXTRACT(MONTH FROM o.target_month)-EXTRACT(MONTH FROM (SELECT first_month FROM bounds))) + 1)::int AS "MonthN",
    o.freq                                                                AS "Freq",
    ( (EXTRACT(YEAR FROM o.target_month)-EXTRACT(YEAR FROM o.last_purchase))*12
    + (EXTRACT(MONTH FROM o.target_month)-EXTRACT(MONTH FROM o.last_purchase)) - 1)::int AS "Recency",
    ( (EXTRACT(YEAR FROM o.last_purchase)-EXTRACT(YEAR FROM o.first_purchase))*12
    + (EXTRACT(MONTH FROM o.last_purchase)-EXTRACT(MONTH FROM o.first_purchase)))::int   AS "Length",
    COALESCE( ( (EXTRACT(YEAR FROM o.last_purchase)-EXTRACT(YEAR FROM o.first_purchase))*12
    + (EXTRACT(MONTH FROM o.last_purchase)-EXTRACT(MONTH FROM o.first_purchase)) )::numeric
      / NULLIF(o.freq,0), -1)                                             AS "Period",
    o.monetary                                                            AS "Monetary",
    av.mean_order                                                         AS "MeanOrderValue",
    av.value_per_order_month                                              AS "ValuePerOrderMonth",
    av.median_order                                                       AS "MedianOrderValue",
    av.max_order                                                          AS "MaxOrderValue",
    o.n_products                                                          AS "DistinctProduct",
    o.n_products::numeric / NULLIF(o.freq,0)                              AS "DistinctProductPerFreq",
    o.monetary / NULLIF(o.n_products,0)                                   AS "MonetaryPerProduct",
    COALESCE(g.max_gap, -1)                                               AS "MaxTimeWithoutPurchase",
    o.last_1 AS "Last1Month", o.last_2 AS "Last2Month", o.last_3 AS "Last3Month",
    o.last_4 AS "Last4Month", o.last_5 AS "Last5Month", o.last_6 AS "Last6Month",
    o.last_7 AS "Last7Month", o.last_8 AS "Last8Month", o.last_9 AS "Last9Month",
    COALESCE(pd.fg / NULLIF(pd.demand,0), -1)                             AS "DemandFGRate",
    COALESCE(pd.ontime_sum::numeric / NULLIF(pd.ontime_cnt,0), -1)        AS "OnTimeRate",
    COALESCE(pd.max_days_late, -1)                                        AS "MaxDaysLate",
    COALESCE(o.disc_wsum / NULLIF(o.revenue,0), -1)                       AS "DiscountRate",
    COALESCE(o.rev_custom / NULLIF(o.revenue,0), -1)                      AS "ShareCustom",
    COALESCE(o.rev_flexo  / NULLIF(o.revenue,0), -1)                      AS "ShareFlexo",
    COALESCE(o.rev_roll   / NULLIF(o.revenue,0), -1)                      AS "ShareRoll",
    -- Kelompok B: share kategori basis LINE-COUNT (penyebut = total line window)
    o.n_paper_cup::numeric      / NULLIF(o.n_lines,0) AS "Share_PaperCup",
    o.n_lid::numeric            / NULLIF(o.n_lines,0) AS "Share_Lid",
    o.n_standing_pouch::numeric / NULLIF(o.n_lines,0) AS "Share_StandingPouch",
    o.n_custom_roll::numeric    / NULLIF(o.n_lines,0) AS "Share_CustomRoll",
    o.n_gusset::numeric         / NULLIF(o.n_lines,0) AS "Share_Gusset",
    o.n_roll_lid_cup::numeric   / NULLIF(o.n_lines,0) AS "Share_RollLidCup",
    o.n_3side::numeric          / NULLIF(o.n_lines,0) AS "Share_3SideSeal",
    o.n_center_seal::numeric    / NULLIF(o.n_lines,0) AS "Share_CenterSeal",
    o.n_label::numeric          / NULLIF(o.n_lines,0) AS "Share_Label",
    (o.n_lines - o.n_paper_cup - o.n_lid - o.n_standing_pouch - o.n_custom_roll
      - o.n_gusset - o.n_roll_lid_cup - o.n_3side - o.n_center_seal - o.n_label)::numeric
      / NULLIF(o.n_lines,0)                            AS "Share_Other",
    -- Tahap C: share MATERIAL per keluarga (line-count, penyebut = total line window)
    o.mm_pet::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_PET",
    o.mm_met::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_MET",
    o.mm_opp::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_OPP",
    o.mm_ny::numeric             / NULLIF(o.n_lines,0) AS "ShareMat_NY",
    o.mm_alu::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_ALU",
    o.mm_dpe::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_DPE",
    o.mm_pcp::numeric            / NULLIF(o.n_lines,0) AS "ShareMat_PCP",
    o.mm_rcpp::numeric           / NULLIF(o.n_lines,0) AS "ShareMat_RCPP",
    o.mm_foopack::numeric        / NULLIF(o.n_lines,0) AS "ShareMat_Foopack",
    o.mm_papersemicoat::numeric  / NULLIF(o.n_lines,0) AS "ShareMat_PaperSemicoat",
    o.mm_pp::numeric             / NULLIF(o.n_lines,0) AS "ShareMat_PP",
    o.mm_pe::numeric             / NULLIF(o.n_lines,0) AS "ShareMat_PE",
    o.mm_plasticlid::numeric     / NULLIF(o.n_lines,0) AS "ShareMat_PlasticLid",
    o.mm_biolid::numeric         / NULLIF(o.n_lines,0) AS "ShareMat_BioLid",
    o.mm_bagasselid::numeric     / NULLIF(o.n_lines,0) AS "ShareMat_BagasseLid",
    o.mm_pplid::numeric          / NULLIF(o.n_lines,0) AS "ShareMat_PPLid",
    o.mm_pettranslid::numeric    / NULLIF(o.n_lines,0) AS "ShareMat_PETTransparentLid",
    o.mm_other::numeric          / NULLIF(o.n_lines,0) AS "ShareMat_Other",
    COALESCE(pf.proof_count::numeric / NULLIF(pf.proof_count + o.freq,0), -1) AS "ProofingRatio",
    COALESCE( ( (EXTRACT(YEAR FROM o.target_month)-EXTRACT(YEAR FROM pf.last_proof))*12
    + (EXTRACT(MONTH FROM o.target_month)-EXTRACT(MONTH FROM pf.last_proof)) - 1)::int, -1) AS "ProofingRecency",
    COALESCE(a.is_returning::int, -1)                                     AS "IsReturning",
    COALESCE(a.is_priority::int, -1)                                      AS "IsPriority",
    a.account_payment_term_name                                           AS "PaymentTerm",
    l.is_buy                                                              AS "IsBuy"
FROM agg_order o
LEFT JOIN agg_value av ON av.cust_id=o.cust_id AND av.target_month=o.target_month
LEFT JOIN agg_prod  pd ON pd.cust_id=o.cust_id AND pd.target_month=o.target_month
LEFT JOIN agg_proof pf ON pf.cust_id=o.cust_id AND pf.target_month=o.target_month
LEFT JOIN agg_gap   g  ON g.cust_id =o.cust_id AND g.target_month =o.target_month
LEFT JOIN agg_attr  a  ON a.cust_id =o.cust_id AND a.target_month =o.target_month
LEFT JOIN label     l  ON l.cust_id =o.cust_id AND l.target_month =o.target_month
WHERE o.freq >= 1
ORDER BY o.target_month, o.cust_id;