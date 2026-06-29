# Automated EEG–ECG Analysis Pipeline for Absence Seizure Detection

This project contains a MATLAB-based pipeline for multichannel EEG analysis and ECG/HRV assessment from EDF recordings. The pipeline screens for absence-seizure-like candidate events using EEG features and summarizes ECG/HRV changes before, during, and after detected events.

## Privacy Notice

Raw clinical EDF files, patient-specific results, and identifiable medical information are not included in this repository.

This repository contains only source code, methodology notes, and anonymized/synthetic screenshots.

## Features

- EDF file loading
- EEG and ECG/EKG channel identification
- Multichannel EEG preprocessing
- 2–5 Hz EEG power-based event screening
- Candidate event detection and confidence scoring
- ECG/EKG channel selection
- Heart rate and HRV analysis
- SDNN and RMSSD calculation
- Before/during/after event comparison
- Automatic figure and report output
- Interactive visual review window

## Methodology Overview

1. Load EDF recording.
2. Identify EEG and ECG/EKG channels.
3. Preprocess EEG channels.
4. Compute 2–5 Hz EEG band activity.
5. Detect candidate absence-seizure-like events.
6. Validate candidates using frequency, duration, and multichannel involvement.
7. Analyze ECG/HRV before, during, and after detected events.
8. Save summary tables, plots, and review screenshots.

## Repository Structure

```text
src/              MATLAB source code
docs/             Methodology and project notes
screenshots/      Anonymized or synthetic screenshots
sample_outputs/   Example output descriptions
