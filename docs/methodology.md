# Methodology

This project implements a MATLAB-based EEG–ECG analysis pipeline for screening absence-seizure-like candidate events from EDF recordings.

## EEG-Based Candidate Detection

The detection pipeline uses multichannel EEG signals. EEG channels are selected, preprocessed, and analyzed in the 2–5 Hz frequency range. Candidate events are identified using seizure-band power, event duration, and multichannel involvement.

## ECG/HRV Analysis

ECG/EKG channels are handled separately. ECG is not used for seizure detection. It is used only to study heart rate and HRV changes around EEG-detected candidate events.

The HRV features include:

- RR interval
- Heart rate
- SDNN
- RMSSD

## Event Segmentation

For each detected candidate event, the pipeline compares:

- Pre-event ECG/HRV
- During-event ECG/HRV
- Post-event ECG/HRV

## Output

The pipeline generates summary tables, figures, screenshots, and review plots.

## Privacy

No raw EDF files, patient identifiers, or clinical metadata are included in this repository.
