import os
from pathlib import Path
import time
import logging
from datetime import datetime
import joblib
import pandas as pd
import numpy as np
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import OneHotEncoder
from sklearn.model_selection import StratifiedKFold, cross_val_score
from catboost import CatBoostClassifier

# Import our custom shared utilities
from src.utils.config_loader import CONFIG
from src.utils.notifications import send_python_exception
from src.utils.ml_db_config import get_engine, get_schema
from src.utils.ml_registry_logger import register_active_model

# ==========================================
# Setup Standardized Logging
# ==========================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("Train_Repeat_Order_Model")
schema = get_schema()

# ==========================================
# Configuration & Constants
# ==========================================
PROJECT_NAME = "repeat_order_prediction"
SOURCE_NAME = Path(__file__).stem
VERSION_NAME = f"catboost_{datetime.now().strftime('%Y%m%d')}"
MODEL_SAVE_DIR = os.getenv("ML_MODEL_SAVE_DIR", "/app/ml_models")
MODEL_PARAMS = {
    'iterations': 300,
    'depth': 8,
    'learning_rate': 0.01410065143862367,
    'l2_leaf_reg': 9.801209200700134,
    'auto_class_weights': 'Balanced',
    'random_state': 42,
    'verbose': False,
}

def run_training_pipeline():
    logger.info("=== STARTING MODEL TRAINING PIPELINE ===")
    start_time = time.time()

    engine = get_engine()

    # 1. Extract Data
    logger.info("Extracting dbt training data (every target_month with a known label)...")

    query = f"""
        SELECT
            freq, recency, length_months, avg_purchase_period_months,
            monetary, mean_order_value, value_per_order_month,
            median_order_value, max_order_value, distinct_product_count,
            distinct_product_per_freq, monetary_per_product, max_time_without_purchase,
            last_1_month, last_2_month, last_3_month,
            last_4_month, last_5_month, last_6_month,
            last_7_month, last_8_month, last_9_month,
            demand_fg_rate, on_time_rate, max_days_late,
            discount_rate, share_custom, share_flexo, share_roll,
            share_paper_cup, share_lid, share_standing_pouch, share_custom_roll,
            share_gusset, share_roll_lid_cup, share_3_side_seal, share_center_seal,
            share_label, share_other,
            share_mat_pet, share_mat_met, share_mat_opp, share_mat_ny, share_mat_alu,
            share_mat_dpe, share_mat_pcp, share_mat_rcpp, share_mat_foopack,
            share_mat_paper_semicoat, share_mat_pp, share_mat_pe, share_mat_plastic_lid,
            share_mat_bio_lid, share_mat_bagasse_lid, share_mat_pp_lid,
            share_mat_pet_transparent_lid, share_mat_other,
            proofing_ratio, proofing_recency, is_returning, is_priority,
            payment_term, target_month, is_buy
        FROM {schema}.mdi_repeat_order_prediction
        WHERE is_buy IS NOT NULL
        ORDER BY target_month, cust_id;
    """
    df = pd.read_sql(query, engine)
    row_count = len(df)

    if row_count < 100:
        logger.error(f"Not enough data for training! Only found {row_count} rows.")
        raise ValueError("Insufficient training data.")

    ## ini buat print bulan paling awal sampai bulan paling akhir
    lower_cutoff_str = df['target_month'].min().strftime('%Y-%m-%d')
    upper_cutoff_str = df['target_month'].max().strftime('%Y-%m-%d')
    logger.info(f"Successfully loaded {row_count} historical customer-months "
                f"({lower_cutoff_str} to {upper_cutoff_str}).")

    # 2. Define Features
    num_features = [
        'freq', 'recency', 'length_months', 'avg_purchase_period_months',
        'monetary', 'mean_order_value', 'value_per_order_month',
        'median_order_value', 'max_order_value', 'distinct_product_count',
        'distinct_product_per_freq', 'monetary_per_product', 'max_time_without_purchase',
        'last_1_month', 'last_2_month', 'last_3_month',
        'last_4_month', 'last_5_month', 'last_6_month',
        'last_7_month', 'last_8_month', 'last_9_month',
        'demand_fg_rate', 'on_time_rate', 'max_days_late',
        'discount_rate', 'share_custom', 'share_flexo', 'share_roll',
        'share_paper_cup', 'share_lid', 'share_standing_pouch', 'share_custom_roll',
        'share_gusset', 'share_roll_lid_cup', 'share_3_side_seal', 'share_center_seal',
        'share_label', 'share_other',
        'share_mat_pet', 'share_mat_met', 'share_mat_opp', 'share_mat_ny', 'share_mat_alu',
        'share_mat_dpe', 'share_mat_pcp', 'share_mat_rcpp', 'share_mat_foopack',
        'share_mat_paper_semicoat', 'share_mat_pp', 'share_mat_pe', 'share_mat_plastic_lid',
        'share_mat_bio_lid', 'share_mat_bagasse_lid', 'share_mat_pp_lid',
        'share_mat_pet_transparent_lid', 'share_mat_other',
        'proofing_ratio', 'proofing_recency', 'is_returning', 'is_priority',
    ]
    cat_features = ['payment_term']
    expected_features = num_features + cat_features

    X = df[expected_features]
    y = df['is_buy']

    # 3. Preprocessing Setup
    preprocessor = ColumnTransformer(
        transformers=[
            ('cat', OneHotEncoder(handle_unknown='ignore', sparse_output=False), cat_features)
        ],
        remainder='passthrough'
    )
    #Transformasi ke bentuk OneHotEncoding untuk kategorikal features


    # ==========================================
    # 4. Evaluate fixed parameters without hyperparameter tuning
    # ==========================================
    logger.info(f"Setting up pipeline with fixed parameters: {MODEL_PARAMS}")

    model = Pipeline(steps=[
        ('preprocessor', preprocessor),
        ('classifier', CatBoostClassifier(**MODEL_PARAMS))
    ])

    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    cv_scores = cross_val_score(model, X, y, cv=cv, scoring='roc_auc')
    cv_roc_auc = float(cv_scores.mean())
    logger.info(f"Fixed-parameter 5-fold ROC AUC: {cv_roc_auc:.4f}")

    logger.info(f"Fitting final model on all {row_count} rows...")
    model.fit(X, y)

    proba_train = model.predict_proba(X)[:, 1]
    bias = float(np.mean(proba_train) - (y == 1).mean())
    logger.info(f"Calibration bias = {bias:.6f}")

    metrics = {
        "cv_roc_auc": round(cv_roc_auc, 4),
        "bias_calibration": round(bias, 6)
    }


    # 6. Save Model to Disk
    os.makedirs(MODEL_SAVE_DIR, exist_ok=True)
    model_file_path = os.path.join(MODEL_SAVE_DIR, f"{PROJECT_NAME}_{VERSION_NAME}.pkl")

    logger.info(f"Saving physical .pkl file to {model_file_path}")
    joblib.dump(model, model_file_path)

    # 7. Register Model in PostgreSQL
    register_active_model(
        engine=engine,
        project_name=PROJECT_NAME,
        version_name=VERSION_NAME,
        data_start=lower_cutoff_str,
        data_cutoff=upper_cutoff_str,
        row_count=row_count,
        metrics=metrics,
        hyperparams=model.named_steps['classifier'].get_params(),
        features=expected_features,
        model_path=model_file_path
    )

    elapsed_time = time.time() - start_time
    logger.info(f"=== TRAINING COMPLETE IN {elapsed_time:.1f} SECONDS ===")

if __name__ == "__main__":
    try:
        run_training_pipeline()
    except Exception as e:
        send_python_exception(
            job_name=PROJECT_NAME,
            source_name=SOURCE_NAME,
            error=e,
            config=CONFIG
        )
        logger.critical(f"Pipeline crashed: {str(e)}", exc_info=True)
        raise