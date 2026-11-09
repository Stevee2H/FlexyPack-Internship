# FlexyPack-Internship
This is the project i've done in my 1 month intership at flexypack. Our project main objective is to forecast flexypack repeat customer using machine learning. But, because i still have plenty of time there, we also create derivative project that is predict repeat order revenue based on repeat customer probability and their bias

MDI_repeat_order_prediction has objective to create feature engineered table from raw table in flexypack database
train_repeat_order_prediction contain catboost with optuna as hyperparameter tuning
predict_repeat_order_prediction contain predict using train catboost model from train_repeat_order_prediction
predict_repeat_order_revenue contain predict revenue by using probability and bias from predict_repeat_order_prediction.

Further more detail could be check at notion:
https://app.notion.com/p/Forecasting-FlexyPack-Repeat-Customer-Using-Machine-Learning-0d13d302aa0383db98c081cec77f99ee?source=copy_link
