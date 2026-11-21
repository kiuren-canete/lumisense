
import os
import sys
import numpy as np
import pandas as pd
import tensorflow as tf
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder, StandardScaler

# ─── CONFIGURATION ───────────────────────────────────────────
EPOCHS = 100
BATCH_SIZE = 16
TEST_SPLIT = 0.2

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(BASE_DIR, 'training_data.csv')
MODEL_DIR = os.path.join(BASE_DIR, 'models')


# ─── STEP 1: LOAD DATA ──────────────────────────────────────
def load_data():
    """Load training data from CSV."""
    print('📂 Loading training data...')

    if not os.path.exists(DATA_FILE):
        print(f'❌ ERROR: {DATA_FILE} not found!')
        print('   Please create a CSV with columns: Avg, Peak, Min, RMS, Label')
        sys.exit(1)

    df = pd.read_csv(DATA_FILE)
    print(f'✓ Loaded {len(df)} samples.')
    print(f'  Classes: {df["Label"].unique().tolist()}')
    print(f'  Samples per class:')
    for label, count in df['Label'].value_counts().items():
        print(f'    {label}: {count}')
    print()

    return df


# ─── STEP 2: PREPARE AND AUGMENT FEATURES ───────────────────────────────
def augment_data(X, y, target_samples_per_class=1000):
    """
    PROFESSIONAL GRADE DATA AUGMENTATION:
    263 rows is not enough for a production AI. We will generate synthetic
    sensor data by injecting realistic Gaussian noise to simulate thousands
    of real-world variations.
    """
    print(f'🧬 Augmenting data to {target_samples_per_class} samples per class...')
    unique_classes = np.unique(y)
    X_aug, y_aug = [], []
    
    for cls in unique_classes:
        # Get all samples for this class
        X_cls = X[y == cls]
        # Keep original data
        X_aug.append(X_cls)
        y_aug.append(np.full(len(X_cls), cls))
        
        # Calculate how many synthetic samples we need to reach the target
        samples_needed = target_samples_per_class - len(X_cls)
        if samples_needed > 0:
            # Generate synthetic data by adding random sensor noise (5% variance)
            std_devs = np.std(X_cls, axis=0)
            # If standard deviation is 0 (e.g. Min is always 0), add a tiny baseline noise
            std_devs[std_devs == 0] = 0.5 
            
            # Randomly pick base samples to mutate
            idx = np.random.randint(0, len(X_cls), samples_needed)
            base_samples = X_cls[idx]
            
            # Inject Gaussian noise
            noise = np.random.normal(0, std_devs * 0.05, size=base_samples.shape)
            synthetic_samples = base_samples + noise
            
            # Ensure Min doesn't drop below 0
            synthetic_samples = np.clip(synthetic_samples, a_min=0, a_max=None)
            
            X_aug.append(synthetic_samples)
            y_aug.append(np.full(samples_needed, cls))
            
    X_combined = np.vstack(X_aug)
    y_combined = np.concatenate(y_aug)
    
    print(f'   Expanded dataset from {len(X)} to {len(X_combined)} samples.')
    return X_combined, y_combined

def prepare_features(df):
    """Extract features, augment them, and scale."""
    # Features: the 4 sensor values
    X = df[['Avg', 'Peak', 'Min', 'RMS']].values.astype(np.float32)

    # Labels: the sound class
    label_encoder = LabelEncoder()
    y = label_encoder.fit_transform(df['Label'])
    
    # Augment the data up to 1000 samples per class
    X, y = augment_data(X, y, target_samples_per_class=1000)

    # Normalize features so the ANN learns faster
    scaler = StandardScaler()
    X = scaler.fit_transform(X).astype(np.float32)

    print(f'✓ Features shape: {X.shape}')
    print(f'  Labels: {list(label_encoder.classes_)}')
    print(f'  Scaler mean: {scaler.mean_.tolist()}')
    print(f'  Scaler std:  {scaler.scale_.tolist()}')
    print()

    return X, y, label_encoder, scaler


# ─── STEP 3: BUILD THE ANN ──────────────────────────────────
def build_ann(num_classes):
    """
    Build a simple, lightweight ANN.
    Input: 4 features (Avg, Peak, Min, RMS)
    Output: probability for each sound class
    """
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(4,)),

        # Hidden layers
        tf.keras.layers.Dense(64, activation='relu'),
        tf.keras.layers.Dropout(0.3),

        tf.keras.layers.Dense(32, activation='relu'),
        tf.keras.layers.Dropout(0.3),

        tf.keras.layers.Dense(16, activation='relu'),

        # Output layer
        tf.keras.layers.Dense(num_classes, activation='softmax'),
    ])

    model.compile(
        optimizer='adam',
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy'],
    )
    return model


# ─── STEP 4: TRAIN ──────────────────────────────────────────
def train_model(X, y, num_classes):
    """Train the ANN."""
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=TEST_SPLIT, random_state=42
    )

    print(f'🧠 Training ANN...')
    print(f'   Train samples: {len(X_train)}')
    print(f'   Test samples:  {len(X_test)}')
    print()

    model = build_ann(num_classes)
    model.summary()

    early_stop = tf.keras.callbacks.EarlyStopping(
        monitor='val_accuracy', patience=15, restore_best_weights=True
    )

    history = model.fit(
        X_train, y_train,
        validation_data=(X_test, y_test),
        epochs=EPOCHS,
        batch_size=BATCH_SIZE,
        callbacks=[early_stop],
        verbose=1,
    )

    loss, accuracy = model.evaluate(X_test, y_test, verbose=0)
    print(f'\n✓ Test Accuracy: {accuracy * 100:.1f}%')
    print(f'  Test Loss: {loss:.4f}')

    return model


# ─── STEP 5: EXPORT ─────────────────────────────────────────
def export_model(model, label_encoder, scaler):
    """Export the trained model to TFLite and save metadata."""
    os.makedirs(MODEL_DIR, exist_ok=True)

    # Convert to TFLite
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()

    model_path = os.path.join(MODEL_DIR, 'sound_classifier.tflite')
    with open(model_path, 'wb') as f:
        f.write(tflite_model)
    print(f'\n✓ TFLite model saved: {model_path}')
    print(f'  Model size: {len(tflite_model) / 1024:.1f} KB')

    # Save class labels
    labels_path = os.path.join(MODEL_DIR, 'class_labels.txt')
    with open(labels_path, 'w') as f:
        for label in label_encoder.classes_:
            f.write(f'{label}\n')
    print(f'✓ Labels saved: {labels_path}')

    # Save scaler parameters (the app needs these to normalize input)
    scaler_path = os.path.join(MODEL_DIR, 'scaler_params.txt')
    with open(scaler_path, 'w') as f:
        f.write(f'mean:{",".join(map(str, scaler.mean_.tolist()))}\n')
        f.write(f'scale:{",".join(map(str, scaler.scale_.tolist()))}\n')
    print(f'✓ Scaler params saved: {scaler_path}')


# ─── MAIN ────────────────────────────────────────────────────
def main():
    print('=' * 60)
    print('  LUMISENSE · ANN Sound Classification Trainer')
    print('  Input: Avg, Peak, Min, RMS (from INMP441 sensor)')
    print('=' * 60)
    print()

    # Step 1
    df = load_data()

    # Step 2
    X, y, label_encoder, scaler = prepare_features(df)
    num_classes = len(label_encoder.classes_)

    # Step 3 & 4
    model = train_model(X, y, num_classes)

    # Step 5
    export_model(model, label_encoder, scaler)

    print()
    print('=' * 60)
    print('  ✅ TRAINING COMPLETE')
    print('  Files ready at: ai_training/models/')
    print('  Copy sound_classifier.tflite → assets/models/')
    print('=' * 60)


if __name__ == '__main__':
    main()
