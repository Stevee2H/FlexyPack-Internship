{{ config(
    materialized='table',
    unique_key='repeat_order_id',
    tags=['monthly', 'repeat_order_prediction']
) }}
/* =====================================================================
   PANEL PREDIKSI REPEAT-ORDER — versi dbt (gaya join-tanggal).
   Window fitur = [target-9bln .. target-1bln]. Label is_buy = beli di bulan target.
   Recency basis t-1. Produksi di-bucket by done_month.
   ===================================================================== */

-- function lines berfungsi buat ngambil raw feature/bahan dasar yang kita butuhkan
WITH lines AS (
    SELECT
        sl.sale_order_partner_id                                      AS cust_id,
        sl.sale_order_id                                              AS sale_order_id,
        sl.sale_order_date_order_actual                               AS order_ts,
        date_trunc('month', sl.sale_order_date_order_actual)::date    AS order_month,
        yf.first_date_finished_done                                   AS done_ts,
        date_trunc('month', yf.first_date_finished_done)::date        AS done_month,
        yf.earliest_production_deadline                               AS deadline_ts,
        
        -- Kategori boolean
        (pr.product_category_name = 'Proofing')                       AS is_proofing_cat,
        (pr.product_category_name IN ('Shipping','All','Jasa','Jasa Design')) AS is_excluded_cat,
        (pr.product_template_custom_product = 'custom')               AS is_custom,
        pr.is_flexo                                                   AS is_flexo,
        pr.product_template_is_roll                                   AS is_roll,
        sl.sale_order_is_returning_customer                           AS is_returning,
        c.is_priority_customer                                        AS is_priority,
        
        -- Angka dan string dasar
        sl.sale_order_line_price_subtotal                             AS line_sub,
        sl.sale_order_line_discount_from_pricelist                    AS disc,
        yf.total_demand_qty                                           AS first_demand_qty,
        yf.total_fg_qty                                               AS first_fg_qty,
        apt.account_payment_term_name                                 AS account_payment_term_name,
        pr.product_category_name                                      AS product_category_name,
        sl.sale_order_line_product_id                                 AS sale_order_line_product_id,

        -- Logika On-time Production
        -- ini buat nyari tau barang itu terlambat apa ngga. Disini menghasilkan either NULL, or 1 atau bisa jg 0
        -- fungsinya supaya output di yg nanti mau dipakai di agg_order, sudah jelas rasionya
        CASE
            WHEN COALESCE(yf.first_date_finished_done, pk.min_picking_date_done) IS NULL 
                 AND yf.earliest_production_deadline > NOW() THEN NULL
            WHEN LEAST(yf.first_date_finished_done, pk.min_picking_date_done) < yf.earliest_production_deadline THEN 1
            ELSE 0
        END AS on_time_production,



        -- Buat kategori material
        CASE
            WHEN pr.product_material_category_name IS NULL THEN 'Other'
            WHEN pr.product_material_category_name ILIKE '%Lid%' THEN pr.product_material_category_name
            WHEN UPPER(pr.product_material_category_name) LIKE 'PAPER SEMICOAT%' THEN 'Paper Semicoat'
            WHEN UPPER(pr.product_material_category_name) LIKE 'FOOPAC%' THEN 'Foopack'
            WHEN UPPER(pr.product_material_category_name) LIKE 'PET%'  THEN 'PET'
            WHEN UPPER(pr.product_material_category_name) LIKE 'MET%'  THEN 'MET'
            WHEN UPPER(pr.product_material_category_name) LIKE 'OPP%'  THEN 'OPP'
            WHEN UPPER(pr.product_material_category_name) LIKE 'NY%'   THEN 'NY'
            WHEN UPPER(pr.product_material_category_name) LIKE 'ALU%'  THEN 'ALU'
            WHEN UPPER(pr.product_material_category_name) LIKE 'DPE%'  THEN 'DPE'
            WHEN UPPER(pr.product_material_category_name) LIKE 'RCPP%' THEN 'RCPP'
            WHEN UPPER(pr.product_material_category_name) LIKE 'PCP%'  THEN 'PCP'
            WHEN UPPER(pr.product_material_category_name) LIKE 'PP%'   THEN 'PP'
            WHEN UPPER(pr.product_material_category_name) LIKE 'PE%'   THEN 'PE'
            ELSE 'Other'
        END AS mat_family

    FROM fct_sps_sale_lines sl
    INNER JOIN dim_sps_products pr          ON sl.sale_order_line_product_id = pr.product_product_id
    INNER JOIN dim_sps_customers c          ON sl.sale_order_partner_id = c.customer_id
    INNER JOIN dim_sps_account_payment_term apt ON sl.sale_order_payment_term_id = apt.account_payment_term_id
    LEFT  JOIN fct_sps_sale_line_yields_first yf ON sl.sale_order_line_id = yf.mrp_production_sale_line_id
    LEFT  JOIN fct_sps_sale_line_picks pk   ON sl.sale_order_line_id = pk.stock_move_sale_line_id
    
    WHERE COALESCE(sl.sale_order_is_partial_parent, false) = false
      AND sl.sale_order_state = 'sale' 
    --   ini karena kita ngga mau ngambil dari parent dan sale_order_statenya harus sale, g boleh yg lain
),

-- Sub-set tabel (Pemisahan data bersih)
purchases  AS (SELECT * FROM lines WHERE NOT is_excluded_cat AND NOT is_proofing_cat),
--purchase fungsinya buat ngeluarin bagian proofing dan bagian-bagian yg kita exclude dari product_category


proofing   AS (SELECT * FROM lines WHERE is_proofing_cat),
--SO_Line proofing ngga akan dipakai. Tapi dari SO Proofing, kita bakal pakai buat IsProofing(cust pernah beli proof ap ngga)

production AS (SELECT * FROM purchases WHERE done_month IS NOT NULL),
-- ini buat batasin kalau bagian data training hanya sampai month yg isi Y-nya ada(bukan NULL)



-- Ini untuk generate rentang waktunya. 
targets AS (
    SELECT generate_series(
        -- Start
        (date_trunc('month', CURRENT_DATE) - interval '4 month')::date,

        -- End: Bulan depan (untuk diprediksi)
        date_trunc('month', CURRENT_DATE)::date, 
        
        interval '1 month'
    )::date AS target_month
),
-- Kalau di run tgl 1 pagi, hapus aja interval 1 month


-- ini basis buat nanti diisi feature n label
base AS (
    SELECT DISTINCT l.cust_id, t.target_month 
    FROM lines l CROSS JOIN targets t
),
-- keywordnya disini, dia ngambil distict ID dan dilakukan cross join lgsg sama bulan-bulan di targets

-- Agregasi Utama
agg_order AS (
    SELECT b.cust_id, b.target_month,
        COUNT(DISTINCT p.sale_order_id)              AS freq,
        COUNT(DISTINCT p.sale_order_line_product_id) AS n_products,
        SUM(p.line_sub)                              AS revenue, -- revenue = monetary
        COALESCE(SUM(p.line_sub) FILTER (WHERE p.is_custom), 0) AS rev_custom,
        COALESCE(SUM(p.line_sub) FILTER (WHERE p.is_flexo), 0)  AS rev_flexo,
        COALESCE(SUM(p.line_sub) FILTER (WHERE p.is_roll), 0)   AS rev_roll,
        -- Ini yg bagian rev, dia ngitung total pendapatan dari custom, flexo, roll

        SUM(p.disc * p.line_sub)                     AS disc_wsum,
        MIN(p.order_month)                           AS first_purchase,
        MAX(p.order_month)                           AS last_purchase,
        
        -- Flag Historis Pembelian 1-9 Bulan Terakhir
        BOOL_OR(p.order_month = b.target_month - interval '1 month')::int AS last_1,
        BOOL_OR(p.order_month = b.target_month - interval '2 month')::int AS last_2,
        BOOL_OR(p.order_month = b.target_month - interval '3 month')::int AS last_3,
        BOOL_OR(p.order_month = b.target_month - interval '4 month')::int AS last_4,
        BOOL_OR(p.order_month = b.target_month - interval '5 month')::int AS last_5,
        BOOL_OR(p.order_month = b.target_month - interval '6 month')::int AS last_6,
        BOOL_OR(p.order_month = b.target_month - interval '7 month')::int AS last_7,
        BOOL_OR(p.order_month = b.target_month - interval '8 month')::int AS last_8,
        BOOL_OR(p.order_month = b.target_month - interval '9 month')::int AS last_9,
        --Fungsinya nyari tau cust itu last1 month - last9 month itu ada pembelian atau ngga
        --Kalau ada, kasi bool 1
        
        -- Count untuk Share Categories
        COUNT(p.sale_order_id)                                         AS n_lines,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Paper Cup')  AS n_paper_cup,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Lid')        AS n_lid,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Standing Pouch') AS n_standing_pouch,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Custom Roll') AS n_custom_roll,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Gusset')     AS n_gusset,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Roll Lid Cup') AS n_roll_lid_cup,
        COUNT(*) FILTER (WHERE p.product_category_name = '3 Side Seal (Sachet)') AS n_3side,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Center Seal') AS n_center_seal,
        COUNT(*) FILTER (WHERE p.product_category_name = 'Label')      AS n_label,
        -- Ini nantinya bakal dipakek buat share_cat. Jadi ngitung presentase roll_lid_cup itu berapa persen dari total semua MATERIAL
        -- Nanti dibawah bakal dipakai Count dari paper cup dibagi Count semua penjualan material



        -- Count untuk Share Material
        COUNT(*) FILTER (WHERE p.mat_family = 'PET')                   AS mm_pet,
        COUNT(*) FILTER (WHERE p.mat_family = 'MET')                   AS mm_met,
        COUNT(*) FILTER (WHERE p.mat_family = 'OPP')                   AS mm_opp,
        COUNT(*) FILTER (WHERE p.mat_family = 'NY')                    AS mm_ny,
        COUNT(*) FILTER (WHERE p.mat_family = 'ALU')                   AS mm_alu,
        COUNT(*) FILTER (WHERE p.mat_family = 'DPE')                   AS mm_dpe,
        COUNT(*) FILTER (WHERE p.mat_family = 'PCP')                   AS mm_pcp,
        COUNT(*) FILTER (WHERE p.mat_family = 'RCPP')                  AS mm_rcpp,
        COUNT(*) FILTER (WHERE p.mat_family = 'Foopack')               AS mm_foopack,
        COUNT(*) FILTER (WHERE p.mat_family = 'Paper Semicoat')        AS mm_papersemicoat,
        COUNT(*) FILTER (WHERE p.mat_family = 'PP')                    AS mm_pp,
        COUNT(*) FILTER (WHERE p.mat_family = 'PE')                    AS mm_pe,
        COUNT(*) FILTER (WHERE p.mat_family = 'Plastic Lid')           AS mm_plasticlid,
        COUNT(*) FILTER (WHERE p.mat_family = 'Bio Lid')               AS mm_biolid,
        COUNT(*) FILTER (WHERE p.mat_family = 'Bagasse Lid')           AS mm_bagasselid,
        COUNT(*) FILTER (WHERE p.mat_family = 'PP Lid')                AS mm_pplid,
        COUNT(*) FILTER (WHERE p.mat_family = 'PET Transparent Lid')   AS mm_pettranslid,
        COUNT(*) FILTER (WHERE p.mat_family = 'Other')                 AS mm_other
        -- Konsepnya mirip sama yg categories diatas tadi

    FROM base b
    LEFT JOIN purchases p ON p.cust_id = b.cust_id 
        AND p.order_month >= b.target_month - interval '9 month' 
        AND p.order_month <  b.target_month
        -- Ini supaya dia ngambil hanya 3 bulan terakhir(tidak termasuk bulan yg mau diprediksi)
    GROUP BY 1, 2
    -- kata lain dari GROUP BY b.cust_id, b.target_month.
),

-- Agregasi Subtotal Order
so_values AS (
    SELECT b.cust_id, b.target_month, p.sale_order_id,
        SUM(p.line_sub) AS so_value,
        MIN(p.order_ts) AS order_ts
    FROM base b 
    JOIN purchases p ON p.cust_id = b.cust_id 
        AND p.order_month >= b.target_month - interval '9 month' 
        AND p.order_month <  b.target_month
    GROUP BY 1, 2, 3
    -- Dalam satu order, mungkin aja 1 order isinya ada 5 barang yg berbeda/5 line. 
    -- Ini nanti dipakek buat ngitung avg, min, max dsb setiap SO di agg_value
),

agg_value AS (
    SELECT cust_id, target_month,
        AVG(so_value) AS mean_order,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY so_value) AS median_order,
        MAX(so_value) AS max_order,
        SUM(so_value) / COUNT(DISTINCT DATE_TRUNC('month', order_ts)) AS value_per_order_month
    FROM so_values GROUP BY 1, 2
    -- Nyari avg, max, median dari tiap sale order
    -- Nyari juga kira-kira value per order monthnya berapa dengan total SO_value dibagi jumlah month dia belanja
),

-- Agregasi Produksi & Proofing
agg_prod AS (
    SELECT b.cust_id, b.target_month,
        SUM(pr.first_fg_qty) AS fg,
        SUM(pr.first_demand_qty) AS demand,
        SUM(pr.on_time_production) AS ontime_sum,
        COUNT(pr.on_time_production) AS ontime_cnt,
        MAX(pr.done_ts::date - pr.deadline_ts::date)::int AS max_days_late
    FROM base b
    LEFT JOIN production pr ON pr.cust_id = b.cust_id 
        AND pr.done_month >= b.target_month - interval '9 month' 
        AND pr.done_month <  b.target_month
    GROUP BY 1, 2
),



agg_proof AS (
    SELECT b.cust_id, b.target_month,
        COUNT(DISTINCT pf.sale_order_id) AS proof_count,
        MAX(pf.order_month) AS last_proof
    FROM base b
    LEFT JOIN proofing pf ON pf.cust_id = b.cust_id 
        AND pf.order_month >= b.target_month - interval '9 month' 
        AND pf.order_month <  b.target_month
    GROUP BY 1, 2
),

-- Menghitung Max Gap (Jeda Terpanjang)
agg_gap AS (
    SELECT cust_id, target_month, MAX(gap_months)::int AS max_gap
    FROM (
        SELECT cust_id, target_month,
               (EXTRACT(YEAR FROM pmonth) - EXTRACT(YEAR FROM prev))*12 + 
               (EXTRACT(MONTH FROM pmonth) - EXTRACT(MONTH FROM prev)) AS gap_months
        FROM (
            SELECT b.cust_id, b.target_month, p.order_month AS pmonth,
                   LAG(p.order_month) OVER (PARTITION BY b.cust_id, b.target_month ORDER BY p.order_month) AS prev
                    -- Ini untuk ngambil bulan belanja sebelumnya. Intinya kalau bulan 8, bakal ngambil data bulan 7
            FROM base b 
            JOIN purchases p ON p.cust_id = b.cust_id 
                AND p.order_month >= b.target_month - interval '9 month' 
                AND p.order_month <  b.target_month
            GROUP BY 1, 2, 3 -- Memastikan distinct pmonth
        ) s WHERE prev IS NOT NULL
    ) g GROUP BY 1, 2
),

-- Atribut Pelanggan Terakhir
agg_attr AS (
    SELECT DISTINCT ON (b.cust_id, b.target_month)
        b.cust_id, b.target_month, p.is_priority, p.account_payment_term_name
    FROM base b 
    JOIN purchases p ON p.cust_id = b.cust_id 
        AND p.order_month >= b.target_month - interval '9 month' 
        AND p.order_month <  b.target_month
    ORDER BY b.cust_id, b.target_month, p.order_ts DESC NULLS LAST
),
-- Ini buat ngambil atribut terakhir dari customer yg cmn bisa diambil di tepat 1 bulan sebelumnya 
-- Freq, monetary dan sejenisnya bisa dihitung dari bulan pertama di window. Tapi kalau IsPrior, bisa berubah-rubah
-- Ambil dari transaksi pertama yg isReturning


-- Pembuatan Target Variable (Y)
label AS (
    SELECT b.cust_id, b.target_month,
        CASE
            WHEN b.target_month >= DATE_TRUNC('month', CURRENT_DATE)::date THEN NULL
            ELSE (COUNT(p.sale_order_id) > 0)::int
        END AS is_buy
        -- Ini tujuannya adalah, apakah bulan target yg kita hitung, sama dengan atau lebih besar dari tanggal 1 di bulan itu
    FROM base b 
    LEFT JOIN purchases p ON p.cust_id = b.cust_id AND p.order_month = b.target_month
    GROUP BY 1, 2
),

first_ret AS (
    SELECT DISTINCT ON (b.cust_id, b.target_month)
        b.cust_id, b.target_month, p.is_returning
    FROM base b
    JOIN purchases p ON p.cust_id = b.cust_id
        AND p.order_month >= b.target_month - interval '9 month'
        AND p.order_month <  b.target_month
    ORDER BY b.cust_id, b.target_month, p.order_ts ASC NULLS LAST
)

/* =====================================================================
   FINAL SELECT - KOMPILASI FITUR & PERHITUNGAN RASIO
   ===================================================================== */
SELECT
    MD5(o.cust_id::text || '_' || o.target_month::text)            AS repeat_order_id, -- ini PK-nya
    o.target_month,
    o.cust_id,
    o.freq,             
    
    -- Metrik Waktu (Recency & Periode)
    ((EXTRACT(YEAR FROM o.target_month) - EXTRACT(YEAR FROM o.last_purchase))*12 
     + (EXTRACT(MONTH FROM o.target_month) - EXTRACT(MONTH FROM o.last_purchase)) - 1)::int AS recency,
    -- Cara hitungnya: (Tahun target - tahun terakhir beli) x 12 
    -- + (bulan target - bulan terakhir beli) -1
    -- di -1 karena kita tidak memasukkan bulan target/prediksi ke dalam sini

    ((EXTRACT(YEAR FROM o.last_purchase) - EXTRACT(YEAR FROM o.first_purchase))*12 
     + (EXTRACT(MONTH FROM o.last_purchase) - EXTRACT(MONTH FROM o.first_purchase)))::int   AS length_months,
    -- Masa hidup dia selama di window
    -- Cara hitungnya, (Tahun terakhir beli - tahun pertama beli) x 12 + 
    -- (Bulan terakhir beli - Bulan pertama beli)


    COALESCE(((EXTRACT(YEAR FROM o.last_purchase) - EXTRACT(YEAR FROM o.first_purchase))*12 
     + (EXTRACT(MONTH FROM o.last_purchase) - EXTRACT(MONTH FROM o.first_purchase)))::numeric 
     / NULLIF(o.freq, 0), -1)                                      AS avg_purchase_period_months,
    -- Mau menghitung rata-rata bulanan dia beli berapa
    -- hitungnya pakai length months tadi/frequency
    COALESCE(g.max_gap, -1)                                        AS max_time_without_purchase,
    -- menghitung max gap tanpa purchase

    
    -- Metrik Keuangan / Nilai Transaksi
    o.revenue                                                      AS monetary,
    av.mean_order                                                  AS mean_order_value,
    av.value_per_order_month,
    av.median_order                                                AS median_order_value,
    av.max_order                                                   AS max_order_value,


    -- Metrik Diversifikasi Produk
    o.n_products                                                   AS distinct_product_count, -- Total jenis produk
    o.n_products::numeric / NULLIF(o.freq, 0)                      AS distinct_product_per_freq,
    o.revenue / NULLIF(o.n_products, 0)                            AS monetary_per_product, -- Jumlah uang yg dihabiskan untuk berapa macam produk
    


    -- Flag Historis Bulanan
    o.last_1 AS last_1_month, o.last_2 AS last_2_month, o.last_3 AS last_3_month,
    o.last_4 AS last_4_month, o.last_5 AS last_5_month, o.last_6 AS last_6_month,
    o.last_7 AS last_7_month, o.last_8 AS last_8_month, o.last_9 AS last_9_month,
    
    -- Metrik Performa Produksi
    COALESCE(pd.fg / NULLIF(pd.demand, 0), -1)                     AS demand_fg_rate,
    -- Dihitung dari kuantitas barang yg selesai / kuantitas barang yg diminta cust

    COALESCE(pd.ontime_sum::numeric / NULLIF(pd.ontime_cnt, 0), -1) AS on_time_rate,
    -- Ngambil dari logika di lines yg bagian ontime

    COALESCE(pd.max_days_late, -1)                                 AS max_days_late, 
    
    -- Metrik Proporsi Penjualan
    COALESCE(o.disc_wsum / NULLIF(o.revenue, 0), -1)               AS discount_rate,
    COALESCE(o.rev_custom / NULLIF(o.revenue, 0), -1)              AS share_custom,
    COALESCE(o.rev_flexo  / NULLIF(o.revenue, 0), -1)              AS share_flexo,
    COALESCE(o.rev_roll   / NULLIF(o.revenue, 0), -1)              AS share_roll,
    -- Ngitung proporsi share rate dengan cara total pendapatan (jenis) / total revenue alias monetary
    -- jenis itu maksudnya custom, flexo or roll or disc



    -- Share Kategori (Berdasarkan Line Count)
    o.n_paper_cup::numeric      / NULLIF(o.n_lines, 0)             AS share_paper_cup,
    o.n_lid::numeric            / NULLIF(o.n_lines, 0)             AS share_lid,
    o.n_standing_pouch::numeric / NULLIF(o.n_lines, 0)             AS share_standing_pouch,
    o.n_custom_roll::numeric    / NULLIF(o.n_lines, 0)             AS share_custom_roll,
    o.n_gusset::numeric         / NULLIF(o.n_lines, 0)             AS share_gusset,
    o.n_roll_lid_cup::numeric   / NULLIF(o.n_lines, 0)             AS share_roll_lid_cup,
    o.n_3side::numeric          / NULLIF(o.n_lines, 0)             AS share_3_side_seal,
    o.n_center_seal::numeric    / NULLIF(o.n_lines, 0)             AS share_center_seal,
    o.n_label::numeric          / NULLIF(o.n_lines, 0)             AS share_label,
    (o.n_lines - o.n_paper_cup - o.n_lid - o.n_standing_pouch - o.n_custom_roll - o.n_gusset 
     - o.n_roll_lid_cup - o.n_3side - o.n_center_seal - o.n_label)::numeric / NULLIF(o.n_lines, 0) AS share_other,
    -- Dari count tiap category sebelumnya, dibagi dengan total semua category. Supaya bisa lihat proporsinya berapa
    -- Untuk others adalah yg tidak termasuk dari category-category yg disebut


    -- Share Material (Berdasarkan Line Count)
    o.mm_pet::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_pet,
    o.mm_met::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_met,
    o.mm_opp::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_opp,
    o.mm_ny::numeric            / NULLIF(o.n_lines, 0)             AS share_mat_ny,
    o.mm_alu::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_alu,
    o.mm_dpe::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_dpe,
    o.mm_pcp::numeric           / NULLIF(o.n_lines, 0)             AS share_mat_pcp,
    o.mm_rcpp::numeric          / NULLIF(o.n_lines, 0)             AS share_mat_rcpp,
    o.mm_foopack::numeric       / NULLIF(o.n_lines, 0)             AS share_mat_foopack,
    o.mm_papersemicoat::numeric / NULLIF(o.n_lines, 0)             AS share_mat_paper_semicoat,
    o.mm_pp::numeric            / NULLIF(o.n_lines, 0)             AS share_mat_pp,
    o.mm_pe::numeric            / NULLIF(o.n_lines, 0)             AS share_mat_pe,
    o.mm_plasticlid::numeric    / NULLIF(o.n_lines, 0)             AS share_mat_plastic_lid,
    o.mm_biolid::numeric        / NULLIF(o.n_lines, 0)             AS share_mat_bio_lid,
    o.mm_bagasselid::numeric    / NULLIF(o.n_lines, 0)             AS share_mat_bagasse_lid,
    o.mm_pplid::numeric         / NULLIF(o.n_lines, 0)             AS share_mat_pp_lid,
    o.mm_pettranslid::numeric   / NULLIF(o.n_lines, 0)             AS share_mat_pet_transparent_lid,
    o.mm_other::numeric         / NULLIF(o.n_lines, 0)             AS share_mat_other,
    --Cara kerjanya persis kyk diatas. Bedanya yg ini material, bukan category


    -- Proofing & Atribut Tambahan
    COALESCE(pf.proof_count::numeric / NULLIF(pf.proof_count + o.freq, 0), -1) AS proofing_ratio,
    -- Cari tau proofing rasionya. Caranya, total dia beli proofing dibagi total pembelian dia selama ini(proof + frekuensi)
    -- Karena proofing tidak masuk ke dalam line, berarti dia ngga masuk ke dalam freq.

    COALESCE(((EXTRACT(YEAR FROM o.target_month) - EXTRACT(YEAR FROM pf.last_proof))*12 
     + (EXTRACT(MONTH FROM o.target_month) - EXTRACT(MONTH FROM pf.last_proof)) - 1)::int, -1) AS proofing_recency,
    -- Mirip rumus resensi sebelumnya, bedanya, kita ambil dari bulan target kita ke bulan terakhir dia proofing
    COALESCE(fr.is_returning::int, -1)                              AS is_returning,
    COALESCE(a.is_priority::int, -1)                               AS is_priority,
    a.account_payment_term_name                                    AS payment_term,
    


    -- Target Variabel
    l.is_buy
    
FROM agg_order o
LEFT JOIN agg_value av ON av.cust_id = o.cust_id AND av.target_month = o.target_month
LEFT JOIN agg_prod  pd ON pd.cust_id = o.cust_id AND pd.target_month = o.target_month
LEFT JOIN agg_proof pf ON pf.cust_id = o.cust_id AND pf.target_month = o.target_month
LEFT JOIN agg_gap   g  ON g.cust_id  = o.cust_id AND g.target_month  = o.target_month
LEFT JOIN agg_attr  a  ON a.cust_id  = o.cust_id AND a.target_month  = o.target_month
LEFT JOIN label     l  ON l.cust_id  = o.cust_id AND l.target_month  = o.target_month
LEFT JOIN first_ret fr ON fr.cust_id = o.cust_id AND fr.target_month = o.target_month
WHERE o.freq >= 1
ORDER BY o.target_month, o.cust_id