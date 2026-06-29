# Automated EEG–ECG Analysis Pipeline for Absence Seizure Detection

This repository contains a MATLAB-based pipeline for multichannel EEG analysis and ECG/HRV assessment from EDF recordings. The pipeline screens for absence-seizure-like candidate events using EEG-based signal features and summarizes ECG/HRV changes before, during, and after detected events.

> **Privacy Note:** Raw clinical EDF files, patient-specific data, and identifiable medical information are not included in this repository.

---

## Overview

Absence seizures are commonly associated with generalized spike-wave activity, often around the 3 Hz range. This project focuses on building a MATLAB analysis workflow to identify absence-seizure-like candidate events from multichannel EEG recordings and then study ECG/HRV changes around those EEG-detected events.

The pipeline uses EEG signals for candidate event detection. ECG/EKG channels are handled separately and are used only for heart rate and HRV analysis.

---

## Key Features

* EDF file loading using MATLAB
* Automatic EEG and ECG/EKG channel identification
* Multichannel EEG preprocessing
* 2–5 Hz EEG band activity analysis
* EEG-based absence-seizure-like candidate event screening
* Candidate event confidence scoring
* ECG/EKG channel selection
* Heart rate analysis
* HRV analysis using RR interval, SDNN, and RMSSD
* Pre-event, during-event, and post-event comparison
* Automatic generation of plots and output summaries
* Interactive visual review window for EEG/ECG inspection
* Sanitized project report and summary outputs

---

## Important Privacy Statement

This repository does **not** include:

* Raw EDF recordings
* Patient names
* Patient IDs
* Hospital IDs
* Clinical identifiers
* Date of birth or age-linked identity information
* Raw clinical metadata
* Any files that can identify the original subjects

Subjects are represented only using anonymized labels such as:

```text
Subject_01
Subject_02
Subject_03
Subject_04
```

---

## Repository Structure

```text
absence-seizure-eeg-ecg-analysis/
│
├── README.md
│
├── src/
│   └── absence_seizure_eeg_ecg_pipeline.m
│
├── docs/
│   └── methodology.md
│
├── screenshots/
│   ├── README.md
│   ├── eeg_candidate_event_viewer.png
│   ├── seizure_band_power_plot.png
│   ├── ecg_hrv_summary.png
│   └── output_folder_structure.png
│
├── project_outputs/
│   ├── README.md
│   ├── report/
│   │   └── absence_seizure_eeg_ecg_analysis_report.pdf
│   │
│   └── tables/
│       └── anonymized_subject_summary.xlsx
│
└── sample_outputs/
    └── README.md
```

---

## Methodology Summary

The pipeline follows this general workflow:

```text
EDF Input
   ↓
Channel Identification
   ↓
EEG Preprocessing
   ↓
2–5 Hz Band Activity Analysis
   ↓
Candidate Event Detection
   ↓
Event Validation and Confidence Scoring
   ↓
ECG/EKG Channel Selection
   ↓
Heart Rate and HRV Analysis
   ↓
Pre/During/Post Event Comparison
   ↓
Plots, Tables, and Report Outputs
```

---

## EEG-Based Candidate Detection

The detection pipeline uses multichannel EEG signals. EEG channels are selected and processed to analyze seizure-band activity, mainly in the 2–5 Hz frequency range.

Candidate events are identified using:

* Increased 2–5 Hz EEG activity
* Event duration criteria
* Multichannel involvement
* Frequency-domain characteristics
* Artifact and confidence checks

ECG is **not** used for seizure detection.

---

## ECG and HRV Analysis

ECG/EKG channels are processed separately after EEG-based candidate events are detected.

ECG/HRV analysis is performed around each candidate event using:

* RR intervals
* Heart rate
* SDNN
* RMSSD

The pipeline compares ECG/HRV changes across:

```text
Pre-event period
During-event period
Post-event period
```

---



## Project Outputs

Sanitized project outputs are available in the `project_outputs/` folder.

Included output examples may contain:

* Final project report
* Subject-wise summary table
* EEG candidate event result summary
* ECG/HRV comparison outputs

The uploaded report and tables use anonymized subject labels only.

---

## Tools and Requirements

This project was developed using:

* MATLAB
* Signal Processing Toolbox
* EDF file handling using MATLAB functions

Recommended MATLAB functions/toolboxes include:

* `edfread`
* `edfinfo`
* Signal filtering functions
* Peak detection functions
* Plotting and table export functions

---

## How to Use

1. Open MATLAB.
2. Open the script located in:

```text
src/absence_seizure_eeg_ecg_pipeline.m
```

3. Run the script.
4. Select an EDF file when prompted.
5. The pipeline will process the EEG/ECG data and generate output files.

> Raw EDF files must be provided locally by the user. They are not included in this repository.

---

## Data Availability

Clinical EDF recordings are not shared because of privacy and institutional restrictions.

Only source code, sanitized screenshots, and anonymized output examples are included.

---

## Disclaimer

This project is intended for academic and research learning purposes only.

It is **not** a clinical diagnostic tool and should not be used for medical decision-making without expert clinical validation.

---

## Author

Developed as part of an academic biomedical engineering internship project.

---

## Suggested Citation

If referencing this project, cite it as:

```text
Automated EEG–ECG Analysis Pipeline for Absence Seizure Detection using MATLAB.
GitHub repository.
```
