# Methodology

## Objective

The objective of this project is to build a MATLAB pipeline for screening absence-seizure-like candidate events from multichannel EEG recordings and studying ECG/HRV changes around those events.

## EEG Analysis

The EEG pipeline identifies available EEG channels, preprocesses the signals, and analyzes activity in the 2–5 Hz range. Candidate events are detected based on increased seizure-band activity, event duration, and multichannel involvement.

## ECG/HRV Analysis

The ECG/EKG channel is selected separately from EEG channels. ECG is not used for seizure detection. It is used only for heart rate and HRV assessment around detected EEG candidate events.

The HRV metrics include:

- RR interval
- SDNN
- RMSSD

## Event Comparison

For every candidate event, ECG/HRV values are compared across:

- Pre-event period
- During-event period
- Post-event period

## Privacy

No raw EDF files, patient identifiers, or clinical metadata are included in this repository.
