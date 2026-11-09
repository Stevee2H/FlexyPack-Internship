import os
from pathlib import Path
import time
import logging
import joblib
import pandas as pd
import numpy as np
from sqlalchemy import MetaData, Table
from sqlalchemy.dialects.postgresql import insert

# Import our custom shared utilities
from src.utils.config_loader import CONFIG
from src.utils.notifications import send_python_exception
from src.utils.ml_db_config import get_engine, get_schema
from src.utils.ml_registry_logger import get_active_model_metadata

# ==========================================
# Setup Standardized Logging
# ==========================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("Predict_Repeat_Order_Model")
schema = get_schema()

# ==========================================
# Configuration & Constants
# ==========================================
PROJECT_NAME = "repeat_order_prediction"
SOURCE_NAME = Path(__file__).stem
# Default to the threshold validated in All_Model/CatBoostPredict.ipynb if the env var isn't set
DECISION_THRESHOLD = float(os.getenv("ROP_DECISION_THRESHOLD", 0.35))


def save_predictions_to_postgres(df_predictions: pd.DataFrame, engine, chunk_size=1000):
    """Idempotent save using PostgreSQL UPSERT."""
    if df_predictions.empty:
        return

    table_name = 'mdo_repeat_order_prediction'
    schema = get_schema()

    # Convert DataFrame to a list of dictionaries
    records = df_predictions.to_dict(orient='records')
    metadata = MetaData()

    with engine.begin() as conn:
        # Load the table definition from the target schema ONCE
        target_table = Table(table_name, metadata, schema=schema, autoload_with=engine)

        # Process in chunks to prevent SQL string memory overload
        for i in range(0, len(records), chunk_size):
            chunk = records[i:i + chunk_size]

            # 1. Pass the chunk directly into the .values() method!
            # This forces SQLAlchemy to build one giant string:
            # INSERT INTO table (...) VALUES (1, 2), (3, 4), (5, 6)...
            stmt = insert(target_table).values(chunk)

            # 2. Define the UPDATE logic
            update_dict = {
                c.name: c for c in stmt.excluded
                if c.name not in ('cust_id', 'target_month')
            }

            # 3. Add the ON CONFLICT clause to the giant string (grain = cust_id + target_month)
            upsert_stmt = stmt.on_conflict_do_update(
                index_elements=['cust_id', 'target_month'],
                set_=update_dict
            )

            # 4. Execute the single giant string (Notice we do NOT pass `chunk` here)
            conn.execute(upsert_stmt)


def run_predict_pipeline():
    logger.info("=== STARTING MIDNIGHT PREDICTION PIPELINE ===")
    start_time = time.time()

    engine = get_engine()

    # 1. Fetch Pending Customer-Months
    # is_buy IS NULL means target_month is the current, still-open month for that customer
    # (see the `label` CTE in mdi_repeat_order_prediction.sql) — this is what we predict.
    logger.info("Fetching unpredicted open-month customers...")
    query = f"""
        SELECT
            cust_id,
            target_month,
            freq,
            recency,
            length_months,
            avg_purchase_period_months,
            monetary,
            mean_order_value,
            value_per_order_month,
            median_order_value,
            max_order_value,
            distinct_product_count,
            distinct_product_per_freq,
            monetary_per_product,
            max_time_without_purchase,
            last_1_month, last_2_month, last_3_month,
            last_4_month, last_5_month, last_6_month,
            last_7_month, last_8_month, last_9_month,
            demand_fg_rate,
            on_time_rate,
            max_days_late,
            discount_rate,
            share_custom,
            share_flexo,
            share_roll,
            share_paper_cup, share_lid, share_standing_pouch, share_custom_roll,
            share_gusset, share_roll_lid_cup, share_3_side_seal, share_center_seal,
            share_label, share_other,
            share_mat_pet, share_mat_met, share_mat_opp, share_mat_ny, share_mat_alu,
            share_mat_dpe, share_mat_pcp, share_mat_rcpp, share_mat_foopack,
            share_mat_paper_semicoat, share_mat_pp, share_mat_pe, share_mat_plastic_lid,
            share_mat_bio_lid, share_mat_bagasse_lid, share_mat_pp_lid,
            share_mat_pet_transparent_lid, share_mat_other,
            proofing_ratio,
            proofing_recency,
            is_returning,
            is_priority,
            payment_term
        FROM {schema}.mdi_repeat_order_prediction
        WHERE is_buy IS NULL
        AND CONCAT(target_month, cust_id)::VARCHAR NOT IN (
            SELECT CONCAT(target_month, cust_id)::VARCHAR
            FROM {schema}.mdo_repeat_order_prediction
        );
    """
    df = pd.read_sql(query, engine)

    if df.empty:
        logger.info("No pending customer-months found. Exiting gracefully.")
        return

    logger.info(f"Found {len(df)} customer-months awaiting prediction.")

    # 2. Get Active Model Metadata from DB
    metadata = get_active_model_metadata(engine, PROJECT_NAME)

    # 3. Load the Physical Model
    logger.info(f"Loading model {metadata['version_name']} from disk...")
    model = joblib.load(metadata["model_path"])
    expected_features = metadata["features"]

    # 4. ENFORCE FEATURE ALIGNMENT
    # This prevents the script from crashing if columns are in the wrong order
    try:
        X_predict = df[expected_features]
    except KeyError as e:
        logger.error(f"Data missing expected features! Expected: {expected_features}. Error: {e}")
        raise

    # 5. Run Predictions
    logger.info("Executing ML predictions...")
    raw_probability = model.predict_proba(X_predict)[:, 1]

    # 6. Post-Processing & Business Logic
    logger.info(f"Applying decision threshold ({DECISION_THRESHOLD})...")

    df['model_version'] = metadata['version_name']
    df['predicted_buy_probability'] = np.clip(raw_probability, 0.0, 1.0)
    df['decision_threshold'] = DECISION_THRESHOLD
    df['is_predicted_buy'] = df['predicted_buy_probability'] >= DECISION_THRESHOLD

    # 7. Prepare for Database Insertion
    df_to_save = df[[
        'cust_id',
        'target_month',
        'model_version',
        'freq',
        'recency',
        'length_months',
        'avg_purchase_period_months',
        'monetary',
        'mean_order_value',
        'value_per_order_month',
        'median_order_value',
        'max_order_value',
        'distinct_product_count',
        'distinct_product_per_freq',
        'monetary_per_product',
        'max_time_without_purchase',
        'last_1_month',
        'last_2_month',
        'last_3_month',
        'last_4_month',
        'last_5_month',
        'last_6_month',
        'last_7_month',
        'last_8_month',
        'last_9_month',
        'demand_fg_rate',
        'on_time_rate',
        'max_days_late',
        'discount_rate',
        'share_custom',
        'share_flexo',
        'share_roll',
        'share_paper_cup',
        'share_lid',
        'share_standing_pouch',
        'share_custom_roll',
        'share_gusset',
        'share_roll_lid_cup',
        'share_3_side_seal',
        'share_center_seal',
        'share_label',
        'share_other',
        'share_mat_pet',
        'share_mat_met',
        'share_mat_opp',
        'share_mat_ny',
        'share_mat_alu',
        'share_mat_dpe',
        'share_mat_pcp',
        'share_mat_rcpp',
        'share_mat_foopack',
        'share_mat_paper_semicoat',
        'share_mat_pp',
        'share_mat_pe',
        'share_mat_plastic_lid',
        'share_mat_bio_lid',
        'share_mat_bagasse_lid',
        'share_mat_pp_lid',
        'share_mat_pet_transparent_lid',
        'share_mat_other',
        'proofing_ratio',
        'proofing_recency',
        'is_returning',
        'is_priority',
        'payment_term',
        'predicted_buy_probability',
        'decision_threshold',
        'is_predicted_buy'
    ]]

    # 8. Save to Database
    logger.info("Upserting predictions into mdo_repeat_order_prediction table...")
    save_predictions_to_postgres(df_to_save, engine)

    elapsed_time = time.time() - start_time
    logger.info(f"=== PREDICTION COMPLETE IN {elapsed_time:.1f} SECONDS ===")


if __name__ == "__main__":
    try:
        run_predict_pipeline()
    except Exception as e:
        send_python_exception(
            job_name=PROJECT_NAME,
            source_name=SOURCE_NAME,
            error=e,
            config=CONFIG
        )
        logger.critical(f"Prediction pipeline crashed: {str(e)}", exc_info=True)
        raise # Ensures the OS/Cron sees a non-zero exit code
