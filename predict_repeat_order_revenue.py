import os
import json
from pathlib import Path
import time
import logging
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
logger = logging.getLogger("Predict_Repeat_Order_Revenue")
schema = get_schema()

# ==========================================
# Configuration & Constants
# ==========================================
# This job REUSES the active IsBuy model's stored calibration; it does not load the .pkl.
PROJECT_NAME = "repeat_order_revenue"   # this job (output table + notifications)
MODEL_PROJECT_NAME = "repeat_order_prediction"   # whose registry row holds bias + version_name
SOURCE_NAME = Path(__file__).stem

# Monte Carlo controls (env-overridable, same spirit as ROP_DECISION_THRESHOLD)
N_ITERATIONS = int(os.getenv("ROP_FORECAST_ITERATIONS", 100_000))
MC_SEED = int(os.getenv("ROP_FORECAST_SEED", 42))
# Iterations processed per batch — caps the (batch x n_cust) draw matrix in RAM
MC_CHUNK = int(os.getenv("ROP_FORECAST_CHUNK", 10_000))


def _monte_carlo(p: np.ndarray, aov: np.ndarray, n_iter: int, seed: int, chunk: int) -> np.ndarray:
    """Bottom-up revenue distribution for one month.

    Each iteration: per customer draw Bernoulli(p); buyers contribute their fixed AOV;
    sum across customers = one simulated monthly total. Chunked over iterations so the
    (n_iter x n_cust) random matrix never materializes all at once.
    """
    rng = np.random.default_rng(seed)
    n_cust = p.shape[0]
    totals = np.empty(n_iter, dtype=float)
    filled = 0
    while filled < n_iter:
        batch = min(chunk, n_iter - filled)
        draws = rng.random((batch, n_cust)) < p        # bool (batch x n_cust)
        totals[filled:filled + batch] = draws @ aov     # (batch,)
        filled += batch
    return totals


def save_forecast_to_postgres(df_forecast: pd.DataFrame, engine, chunk_size=1000):
    """Idempotent save using PostgreSQL UPSERT (grain = target_month + model_version)."""
    if df_forecast.empty:
        return

    table_name = 'mdo_repeat_order_revenue'
    schema = get_schema()

    records = df_forecast.to_dict(orient='records')
    metadata = MetaData()

    with engine.begin() as conn:
        target_table = Table(table_name, metadata, schema=schema, autoload_with=engine)

        for i in range(0, len(records), chunk_size):
            chunk = records[i:i + chunk_size]
            stmt = insert(target_table).values(chunk)

            update_dict = {
                c.name: c for c in stmt.excluded
                if c.name not in ('target_month', 'model_version')
            }

            upsert_stmt = stmt.on_conflict_do_update(
                index_elements=['target_month', 'model_version'],
                set_=update_dict
            )
            conn.execute(upsert_stmt)


def run_forecast_pipeline():
    logger.info("=== STARTING REVENUE FORECAST PIPELINE ===")
    start_time = time.time()

    engine = get_engine()

    # 1. Read the active model's registry row for version_name + stored calibration bias.
    #    (No .pkl load, no predict_proba — proba is already persisted in mdo.)
    metadata = get_active_model_metadata(engine, MODEL_PROJECT_NAME)
    model_version = metadata["version_name"]

    # metrics tidak disurfaced get_active_model_metadata → baca langsung dari registry
    row = pd.read_sql(
        f"SELECT metrics FROM {schema}.mdl_ml_registry "
        f"WHERE version_name = %(vn)s",
        engine, params={"vn": model_version},
    )
    if row.empty:
        raise ValueError(f"No registry row for version {model_version}.")

    raw_metrics = row.iloc[0]["metrics"]
    metrics = json.loads(raw_metrics) if isinstance(raw_metrics, str) else raw_metrics
    if "bias_calibration" not in metrics:
        raise KeyError(
            "Active model has no stored 'bias' in metrics. "
            "Retrain with the bias-saving train script before forecasting."
        )
    bias = float(metrics["bias_calibration"])
    logger.info(f"Using model {model_version} with stored calibration bias = {bias:.6f}")

    # 2. Fetch open-month rows to forecast, straight from mdo (proba already computed by predict job).
    #    mdo has no is_buy column; "open months" = target_month in the current month onward,
    #    which mirrors the is_buy IS NULL definition in the mdi panel.
    logger.info("Fetching open-month predictions from mdo...")
    df = pd.read_sql(
        f"SELECT cust_id, target_month, predicted_buy_probability, value_per_order_month "
        f"FROM {schema}.mdo_repeat_order_prediction "
        f"WHERE model_version = %(mv)s "
        f"  AND target_month >= date_trunc('month', CURRENT_DATE)::date",
        engine,
        params={"mv": model_version},
    )

    if df.empty:
        logger.info("No open-month predictions found in mdo. Did the predict job run? Exiting gracefully.")
        return

    logger.info(f"Forecasting {df['target_month'].nunique()} open month(s), "
                f"{len(df)} customer-rows total.")

    # 3. Calibrated proba = stored probability - bias, clipped to [0, 1].
    #    (predicted_buy_probability was already clipped to [0, 1] when the predict job wrote it.)
    df['calibrated_proba'] = np.clip(df['predicted_buy_probability'] - bias, 0.0, 1.0)

    # 4. Spend-if-buy = value_per_order_month; zero out non-positive / non-finite (notebook TAHAP 5)
    aov = df['value_per_order_month'].to_numpy(dtype=float)
    df['aov'] = np.where(np.isfinite(aov) & (aov > 0), aov, 0.0)

    # 5. Monte Carlo per target_month (aggregate monthly revenue distribution — returning customers only)
    results = []
    for month, g in df.groupby('target_month'):
        p = g['calibrated_proba'].to_numpy(dtype=float)
        a = g['aov'].to_numpy(dtype=float)

        totals = _monte_carlo(p, a, N_ITERATIONS, MC_SEED, MC_CHUNK)
        p2_5, p50, p97_5 = np.percentile(totals, [2.5, 50, 97.5])

        results.append({
            'target_month': month,
            'model_version': model_version,
            'n_customers_simulated': int(len(g)),
            'estimated_buyers': float(p.sum()),
            'forecast_pessimistic_p2_5': float(p2_5),
            'forecast_median_p50': float(p50),
            'forecast_mean': float(totals.mean()),
            'forecast_optimistic_p97_5': float(p97_5),
            'forecast_max': float(totals.max()),
            'bias_calibration': float(bias),
            'n_iterations': int(N_ITERATIONS),
        })

        logger.info(f"[{month}] mean={totals.mean():,.0f} | "
                    f"P2.5={p2_5:,.0f} P50={p50:,.0f} P97.5={p97_5:,.0f} | "
                    f"buyers~{p.sum():,.0f}/{len(g)}")

    df_out = pd.DataFrame(results)

    # 6. Save aggregate forecast
    logger.info("Upserting forecasts into mdo_repeat_order_revenue table...")
    save_forecast_to_postgres(df_out, engine)

    elapsed_time = time.time() - start_time
    logger.info(f"=== FORECAST COMPLETE IN {elapsed_time:.1f} SECONDS ===")


if __name__ == "__main__":
    try:
        run_forecast_pipeline()
    except Exception as e:
        send_python_exception(
            job_name=PROJECT_NAME,
            source_name=SOURCE_NAME,
            error=e,
            config=CONFIG
        )
        logger.critical(f"Forecast pipeline crashed: {str(e)}", exc_info=True)
        raise  # Ensures the OS/Cron sees a non-zero exit code