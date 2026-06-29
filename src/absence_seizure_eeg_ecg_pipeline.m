clc;
clear;
close all;
fclose('all');

%% ============================================================
% EEG-ONLY MULTI-CHANNEL ABSENCE-SEIZURE-LIKE EVENT PIPELINE - v6 CLEAN FINAL
%
% MAIN GOAL:
% 1. Load EDF patient file
% 2. Auto-detect EEG and ECG/EKG channels
% 3. Remove unusable EEG channels automatically
% 4. Detect possible absence-seizure-like windows using EEG ONLY
% 5. Use ECG only AFTER EEG detection for HR / HRV reporting
% 6. Save Excel/CSV, screenshots, graph-only PDF, and review viewer
%
% IMPORTANT RULE:
% - ECG / EKG is NOT used for seizure detection or final decision.
% - ECG / EKG is used only after EEG event detection for HR, SDNN, RMSSD,
%   and visual checking during the same event window.
%
% This is biomedical signal-analysis classification only.
% This is NOT clinical diagnosis.
%% ============================================================

%% ============================================================
% BLOCK 1: PRE-DATA / INPUT SETTINGS
%% ============================================================

%% ---------------- SELECT EDF FILE ----------------
[file_name, input_folder] = uigetfile( ...
    {'*.edf','EDF Files (*.edf)'}, ...
    'Select the EDF file to analyze');

if isequal(file_name, 0)
    error('No EDF file selected. Program stopped.');
end

filename = fullfile(input_folder, file_name);
[~, edf_base_name, ~] = fileparts(file_name);
safe_subject_name = matlab.lang.makeValidName(edf_base_name);

num_match = regexp(edf_base_name, '\d+', 'match');
if ~isempty(num_match)
    sub_no = str2double(num_match{end});
else
    sub_no = 1;
end

%% ---------------- SELECT OUTPUT FOLDER ----------------
default_downloads = fullfile(getenv('USERPROFILE'), 'Downloads');
if ~isfolder(default_downloads)
    default_downloads = pwd;
end

selected_output_folder = uigetdir(default_downloads, ...
    'Select folder where results should be saved');

if isequal(selected_output_folder, 0)
    error('No output folder selected. Program stopped.');
end

%% ---------------- OUTPUT FOLDER SETUP ----------------
main_output_folder = fullfile(selected_output_folder, 'SEIZURE_OUTPUT');
subject_folder = fullfile(main_output_folder, safe_subject_name);
plots_folder = fullfile(subject_folder, 'Plots');
screenshots_folder = fullfile(subject_folder, 'Event_Screenshots');
reports_folder = fullfile(subject_folder, 'Reports');
tables_folder = fullfile(subject_folder, 'Tables');
check_folder = fullfile(subject_folder, 'Checking_Pipeline');
pipeline_folder = fullfile(subject_folder, 'Pipeline_Explanation');

if ~isfolder(main_output_folder)
    mkdir(main_output_folder);
end

%% ---------------- DELETE OLD OUTPUT FOR SAME EDF ----------------
if isfolder(subject_folder)
    fprintf('\nOld output folder found. Deleting old folder:\n%s\n', subject_folder);
    delete_success = false;

    for delete_try = 1:5
        try
            fclose('all');
            close all force;
            pause(0.5);
            rmdir(subject_folder, 's');
            delete_success = true;
            fprintf('Old output folder deleted successfully.\n');
            break;
        catch
            fprintf('Delete attempt %d failed. Close old PDF/Excel/images if open.\n', delete_try);
            pause(1);
        end
    end

    if ~delete_success
        error('Could not delete old output folder. Close open files from: %s', subject_folder);
    end
end

mkdir(subject_folder);
mkdir(plots_folder);
mkdir(screenshots_folder);
mkdir(reports_folder);
mkdir(tables_folder);
mkdir(check_folder);
mkdir(pipeline_folder);

%% ---------------- FILTER SETTINGS ----------------
eeg_filter_band = [0.5 30];       % cleaned EEG display + analysis band
ecg_filter_band = [5 20];         % ECG R-peak / HRV band
detect_band = [2 5];              % broad absence / spike-wave band
absence_core_band = [2.5 4.0];    % stricter typical absence core band

%% ---------------- EEG REFERENCE / MONTAGE SETTING ----------------
% AS_RECORDED is safest for generalized absence patterns because common
% average referencing can reduce very widespread synchronous activity.
% Change to "COMMON_AVERAGE" only if your supervisor specifically wants it.
eeg_reference_mode = "AS_RECORDED";

%% ---------------- DETECTION SETTINGS ----------------
threshold_factor = 3.8;           % higher = stricter, reduces false detections
morphology_threshold_factor = 2.6; % stricter line-length / spike-wave morphology threshold
ignore_start_sec = 30;

% Candidate duration rules
% Typical absence is usually short, but clearly generalized spike-wave activity
% can continue longer. So we keep 5-30 sec as FINAL typical-absence range,
% and 30-180 sec as PROLONGED REVIEW instead of deleting it.
min_seizure_duration = 5;
typical_max_seizure_duration = 30;
prolonged_review_max_duration = 180;
max_seizure_duration = prolonged_review_max_duration;

% Close fragments are merged first, then duration is checked.
% Larger gap helps join one long generalized spike-wave run that has tiny breaks.
merge_gap_sec = 12;

% 30 sec context window used for validation around each candidate
checking_window_sec = 30;
before_after_sec = 20;
screenshot_padding_sec = 10;

% If two final/review events are too close, keep only the strongest one.
% This prevents one seizure-like zone from producing repeated nearby detections.
event_competition_sec = 60;

% Multi-channel rule
min_detect_channel_fraction = 0.35;  % stricter initial candidate creation
min_final_channel_fraction = 0.65;   % final event validation
min_review_channel_fraction = 0.50;  % weaker review windows, still stricter than before

% EEG validation thresholds
min_power_rise_final = 5.0;
min_power_rise_review = 3.2;
min_spectral_ratio_final = 0.32;
min_spectral_ratio_review = 0.24;
min_line_length_ratio_final = 1.45;
min_line_length_ratio_review = 1.25;
min_sharpness_ratio_final = 1.30;
min_sharpness_ratio_review = 1.15;
max_artifact_amp_score = 45;

% Confidence grading
high_confidence_cutoff = 75;
medium_confidence_cutoff = 50;

% Event color marking rule used in full plot, screenshots, PDF, and viewer
% RED    = very possible / likely EEG event
% YELLOW = suspicious / review-needed EEG event
% GREEN  = weak possibility / low-confidence review window
red_review_confidence_cutoff = 55;
yellow_review_confidence_cutoff = medium_confidence_cutoff;

% PDF rules
pdf_screenshots_only = true;
save_tables_separately = true;

fprintf('\n============================================================\n');
fprintf('BLOCK 1 COMPLETE: SETTINGS READY\n');
fprintf('EDF File Selected: %s\n', filename);
fprintf('Subject Name: %s\n', safe_subject_name);
fprintf('Subject Number: %d\n', sub_no);
fprintf('Fresh Output Folder: %s\n', subject_folder);
fprintf('Detection rule: EEG ONLY. ECG is post-detection only.\n');
fprintf('============================================================\n\n');

%% ============================================================
% BLOCK 2: LOAD EDF PRE-DATA
%% ============================================================

fprintf('\n============================================\n');
fprintf('Processing subject: sub_%d\n', sub_no);
fprintf('File: %s\n', filename);
fprintf('============================================\n');

if ~isfile(filename)
    error('EDF file not found. Check filename/path.');
end

[data, info, filename] = loadEDFFixReservedOnly(filename);

labels = string(data.Properties.VariableNames);
labels = labels(:);
labels_upper = upper(strtrim(labels));

original_labels = upper(strtrim(string(info.SignalLabels)));
original_labels = original_labels(:);

total_duration_original = getTotalDurationSec(info);

fprintf('EDF loaded successfully.\n');
fprintf('Signals: %d\n', width(data));
fprintf('Original duration: %.2f sec / %.2f min\n', ...
    total_duration_original, total_duration_original/60);

%% ============================================================
% BLOCK 3: CHANNEL DETECTION
% - EEG channels are used for detection.
% - ECG/EKG channels are detected but NOT used for seizure detection.
%% ============================================================

%% ---------------- EEG CHANNEL DETECTION ----------------
% Robust EEG detection:
% This works for both:
%   EEG Fp1 / EEGFP1 style labels
%   Fp1-AR / F8-AR / C3-A1 / O2-AR style labels
% ECG/EKG is still excluded from EEG detection.

eeg_channels = detectEEGChannelsFlexible(labels, original_labels);
eeg_channels = unique(eeg_channels(:), 'stable');

if isempty(eeg_channels)
    fprintf('\nAvailable EDF labels were:\n');
    disp(original_labels')
    error('No usable EEG channels found. Channel labels are not recognized. Add the label pattern to detectEEGChannelsFlexible().');
end

%% ---------------- ECG / EKG CHANNEL DETECTION ----------------
% ECG detection is label-based only. If this EDF has no real ECG/EKG label,
% HR/HRV will be NaN but EEG detection continues normally.

ecg_channels = detectECGChannelsFlexible(labels, original_labels);
ecg_channels = unique(ecg_channels(:), 'stable');

if isempty(ecg_channels)
    ecg_channel = [];
else
    ecg_channel = ecg_channels(1);
end

fprintf('\nDetected EEG channels before quality cleanup:\n');
disp(labels(eeg_channels)')

if isempty(ecg_channels)
    fprintf('No ECG/EKG channel detected. HR/HRV will be NaN.\n');
else
    fprintf('Detected ECG/EKG channels, post-detection only:\n');
    for i = 1:length(ecg_channels)
        fprintf('  %d) %s\n', i, char(labels(ecg_channels(i))));
    end
end

%% ============================================================
% BLOCK 4: SAMPLING RATE + EEG PREPROCESSING + BAD CHANNEL REMOVAL
%% ============================================================

fs_list = zeros(length(eeg_channels), 1);

for k = 1:length(eeg_channels)
    sig = getSignal(data, eeg_channels(k));
    fs_list(k) = length(sig) / total_duration_original;
end

Fs = mode(round(fs_list));

fprintf('\nUniversal Fs: %.2f Hz\n', Fs);
fprintf('Total duration: %.2f sec / %.2f min\n', ...
    total_duration_original, total_duration_original/60);

eeg_temp = cell(length(eeg_channels), 1);
min_len = inf;

for k = 1:length(eeg_channels)

    sig = getSignal(data, eeg_channels(k));
    Fs_ch = length(sig) / total_duration_original;

    if round(Fs_ch) ~= round(Fs)
        [p, q] = rat(Fs/Fs_ch);
        sig = resample(sig, p, q);
    end

    sig = double(sig(:));
    sig = fillmissing(sig, 'linear', 'EndValues', 'nearest');
    sig = sig - mean(sig, 'omitnan');
    sig = applyNotch50Hz(sig, Fs);
    sig = bandpass(sig, eeg_filter_band, Fs);
    sig = sig - mean(sig, 'omitnan');

    eeg_temp{k} = sig;
    min_len = min(min_len, length(sig));
end

%% ---------------- CREATE TEMP EEG MATRIX ----------------
eeg_matrix_all = zeros(min_len, length(eeg_channels));
for k = 1:length(eeg_channels)
    eeg_matrix_all(:, k) = eeg_temp{k}(1:min_len);
end

t = (0:min_len-1)' / Fs;
total_duration = max(t);

%% ---------------- REMOVE BAD / STATIC EEG CHANNELS ----------------
[good_eeg_mask, channel_quality_table] = getEEGChannelQuality(eeg_matrix_all, Fs, labels(eeg_channels));
removed_eeg_channels = eeg_channels(~good_eeg_mask);
removed_eeg_labels = labels(removed_eeg_channels);

eeg_channels = eeg_channels(good_eeg_mask);
eeg_matrix = eeg_matrix_all(:, good_eeg_mask);

if isempty(eeg_channels)
    error('All EEG channels were rejected as bad/static. Relax quality rules or inspect EDF.');
end

%% ---------------- OPTIONAL EEG REFERENCE / MONTAGE ----------------
switch upper(string(eeg_reference_mode))
    case "AS_RECORDED"
        eeg_detect_matrix = eeg_matrix;
        montage_note = "AS_RECORDED: no re-reference applied";

    case "COMMON_AVERAGE"
        common_ref = median(eeg_matrix, 2, 'omitnan');
        eeg_detect_matrix = eeg_matrix - common_ref;
        montage_note = "COMMON_AVERAGE: median common reference removed";

    otherwise
        eeg_detect_matrix = eeg_matrix;
        montage_note = "UNKNOWN SETTING -> AS_RECORDED used";
end

channel_quality_file = fullfile(tables_folder, sprintf('sub_%d_EEG_Channel_Quality.xlsx', sub_no));
writetable(channel_quality_table, channel_quality_file);

fprintf('\nEEG preprocessing completed.\n');
fprintf('EEG filter: 50 Hz notch + %.1f-%.1f Hz bandpass.\n', ...
    eeg_filter_band(1), eeg_filter_band(2));
fprintf('Montage/reference mode: %s\n', montage_note);
fprintf('Usable EEG channels after cleanup: %d\n', length(eeg_channels));

if ~isempty(removed_eeg_channels)
    fprintf('Removed bad/static EEG channels:\n');
    disp(removed_eeg_labels')
else
    fprintf('No EEG channels removed by quality cleanup.\n');
end

%% ============================================================
% BLOCK 5: ECG / EKG PREPROCESSING
% ECG is NOT used for detection. It is only for post-event HR/HRV/reporting.
%
% ECG rule:
% - All ECG/EKG channels are checked separately.
% - Useless ECG/EKG channels are rejected first:
%     flat/static channels
%     mostly repeated-value channels
%     smooth single-frequency sine-like channels
%     channels with too few believable QRS/R-like peaks
% - The best remaining single raw-looking ECG/EKG is selected by R-peak quality.
% - No ECG averaging.
% - No ECG overlap/combination.
%% ============================================================

has_ecg = ~isempty(ecg_channels);
target_len = length(t);

if has_ecg

    n_ecg = length(ecg_channels);

    ecg_raw_matrix = nan(target_len, n_ecg);
    ecg_filt_matrix = nan(target_len, n_ecg);
    ecg_display_matrix = nan(target_len, n_ecg);

    ecg_quality_score = nan(n_ecg, 1);
    ecg_est_hr_bpm = nan(n_ecg, 1);
    ecg_rpeak_count = zeros(n_ecg, 1);
    ecg_best_polarity = strings(n_ecg, 1);
    ecg_quality_note = strings(n_ecg, 1);
    ecg_channel_name = strings(n_ecg, 1);

    ecg_is_usable = false(n_ecg, 1);
    ecg_reject_reason = strings(n_ecg, 1);
    ecg_adjusted_score = nan(n_ecg, 1);
    ecg_raw_robust_range = nan(n_ecg, 1);
    ecg_repeated_fraction = nan(n_ecg, 1);
    ecg_sine_dominance = nan(n_ecg, 1);
    ecg_qrs_rate_per_min = nan(n_ecg, 1);

    for ch_i = 1:n_ecg

        this_ecg_ch = ecg_channels(ch_i);
        ecg_channel_name(ch_i) = string(labels(this_ecg_ch));

        ecg_raw_temp = getSignal(data, this_ecg_ch);
        Fs_ecg = length(ecg_raw_temp) / total_duration_original;

        ecg_raw_temp = resampleAndMatchLength(ecg_raw_temp, Fs_ecg, Fs, target_len);
        ecg_raw_temp = fillmissing(ecg_raw_temp, 'linear', 'EndValues', 'nearest');
        ecg_raw_temp = ecg_raw_temp - median(ecg_raw_temp, 'omitnan');

        ecg_raw_matrix(:, ch_i) = ecg_raw_temp;

        % Filter used only for R-peak/HRV scoring.
        ecg_for_hrv = applyNotch50Hz(ecg_raw_temp, Fs);
        ecg_low = ecg_filter_band(1);
        ecg_high = min(ecg_filter_band(2), 0.45 * Fs);

        if ecg_high > ecg_low && ecg_high < Fs/2
            ecg_filt_temp = bandpass(ecg_for_hrv, [ecg_low ecg_high], Fs);
        else
            ecg_filt_temp = ecg_for_hrv;
        end

        ecg_filt_temp = ecg_filt_temp - median(ecg_filt_temp, 'omitnan');
        ecg_filt_matrix(:, ch_i) = ecg_filt_temp;

        % Display ECG is wider-band so the shape looks closer to raw ECG.
        % It is still only selected best ECG, not combined.
        ecg_for_display = applyNotch50Hz(ecg_raw_temp, Fs);
        display_high = min(40, 0.45 * Fs);

        if display_high > 0.5 && display_high < Fs/2
            ecg_display_temp = bandpass(ecg_for_display, [0.5 display_high], Fs);
        else
            ecg_display_temp = ecg_for_display;
        end

        ecg_display_temp = ecg_display_temp - median(ecg_display_temp, 'omitnan');
        ecg_display_matrix(:, ch_i) = ecg_display_temp;

        [this_score, this_hr, this_count, this_polarity, this_note] = ...
            getBestECGChannelScore(ecg_filt_temp, Fs);

        [this_usable, this_reject_reason, this_adj_score, this_range, ...
            this_repeat_frac, this_sine_dom, this_qrs_rate] = ...
            rejectUselessECGChannel(ecg_raw_temp, ecg_filt_temp, Fs, ...
            this_score, this_hr, this_count);

        ecg_quality_score(ch_i) = this_score;
        ecg_est_hr_bpm(ch_i) = this_hr;
        ecg_rpeak_count(ch_i) = this_count;
        ecg_best_polarity(ch_i) = this_polarity;
        ecg_is_usable(ch_i) = this_usable;
        ecg_reject_reason(ch_i) = this_reject_reason;
        ecg_adjusted_score(ch_i) = this_adj_score;
        ecg_raw_robust_range(ch_i) = this_range;
        ecg_repeated_fraction(ch_i) = this_repeat_frac;
        ecg_sine_dominance(ch_i) = this_sine_dom;
        ecg_qrs_rate_per_min(ch_i) = this_qrs_rate;

        if this_usable
            ecg_quality_note(ch_i) = string(this_note) + " | USABLE ECG";
        else
            ecg_quality_note(ch_i) = string(this_note) + " | REJECTED: " + this_reject_reason;
        end
    end

    selection_score = ecg_adjusted_score;
    selection_score(~ecg_is_usable) = -Inf;
    selection_score(~isfinite(selection_score)) = -Inf;

    [~, best_ecg_idx] = max(selection_score);

    Selected = false(n_ecg, 1);

    if any(ecg_is_usable) && isfinite(selection_score(best_ecg_idx))
        Selected(best_ecg_idx) = true;

        ecg_channel = ecg_channels(best_ecg_idx);
        ecg_raw = ecg_raw_matrix(:, best_ecg_idx);
        ecg_filt = ecg_filt_matrix(:, best_ecg_idx);
        ecg_display = ecg_display_matrix(:, best_ecg_idx);
        has_ecg = true;
    else
        % Important: do NOT silently use a bad sine/static ECG just because
        % it has an ECG/EKG label. If no channel passes quality rules, ECG
        % is treated as unavailable for HR/HRV, but EEG detection still runs.
        ecg_channel = [];
        ecg_raw = nan(target_len, 1);
        ecg_filt = nan(target_len, 1);
        ecg_display = nan(target_len, 1);
        has_ecg = false;
    end

    ECG_Index = (1:n_ecg)';
    ECG_Channel_Number = ecg_channels(:);
    ECG_Channel_Name = ecg_channel_name(:);
    Quality_Score = ecg_quality_score(:);
    Adjusted_Selection_Score = ecg_adjusted_score(:);
    Estimated_HR_bpm = ecg_est_hr_bpm(:);
    RPeak_Count = ecg_rpeak_count(:);
    QRS_Rate_Per_Min = ecg_qrs_rate_per_min(:);
    Raw_Robust_Range = ecg_raw_robust_range(:);
    Repeated_Value_Fraction = ecg_repeated_fraction(:);
    Single_Frequency_Dominance = ecg_sine_dominance(:);
    Best_Polarity = ecg_best_polarity(:);
    Usable_ECG = ecg_is_usable(:);
    Reject_Reason = ecg_reject_reason(:);
    Quality_Note = ecg_quality_note(:);

    ecg_quality_table = table( ...
        ECG_Index, ECG_Channel_Number, ECG_Channel_Name, Quality_Score, ...
        Adjusted_Selection_Score, Estimated_HR_bpm, RPeak_Count, ...
        QRS_Rate_Per_Min, Raw_Robust_Range, Repeated_Value_Fraction, ...
        Single_Frequency_Dominance, Best_Polarity, Usable_ECG, ...
        Reject_Reason, Quality_Note, Selected);

    ecg_quality_file = fullfile(tables_folder, sprintf('sub_%d_ECG_Channel_Selection.xlsx', sub_no));
    writetable(ecg_quality_table, ecg_quality_file);

else
    ecg_channel = [];
    ecg_raw_matrix = nan(target_len, 1);
    ecg_filt_matrix = nan(target_len, 1);
    ecg_display_matrix = nan(target_len, 1);
    ecg_quality_score = NaN;
    ecg_raw = nan(target_len, 1);
    ecg_filt = nan(target_len, 1);
    ecg_display = nan(target_len, 1);

    ecg_quality_table = table("NO ECG/EKG CHANNEL FOUND", ...
        'VariableNames', {'Status'});
    ecg_quality_file = fullfile(tables_folder, sprintf('sub_%d_ECG_Channel_Selection.xlsx', sub_no));
    writetable(ecg_quality_table, ecg_quality_file);
end

fprintf('\nECG/EKG preprocessing completed. ECG is post-detection only.\n');

if has_ecg
    fprintf('Selected best single ECG/EKG channel: %s\n', char(labels(ecg_channel)));
    fprintf('ECG selection table saved: %s\n', ecg_quality_file);
else
    if ~isempty(ecg_channels)
        fprintf('ECG/EKG labels were found, but all were rejected as useless/static/sine-like or too weak for HRV.\n');
        fprintf('EEG detection will continue normally. HR/HRV will be NaN.\n');
        fprintf('ECG rejection table saved: %s\n', ecg_quality_file);
    else
        fprintf('No ECG/EKG channel found.\n');
    end
end


%% ============================================================
% BLOCK 6: EEG-ONLY MULTI-CHANNEL CANDIDATE DETECTION
% Detection factors:
% - 2-5 Hz power increase per EEG channel
% - multi-channel spread
% - line-length/morphology support
% - no ECG input used anywhere here
%% ============================================================

fprintf('\nRunning EEG-only multi-channel detection...\n');

num_eeg_channels = size(eeg_detect_matrix, 2);
min_detect_channels = max(2, ceil(min_detect_channel_fraction * num_eeg_channels));
min_detect_channels = min(min_detect_channels, num_eeg_channels);

fprintf('Total usable EEG channels: %d\n', num_eeg_channels);
fprintf('Minimum channels needed for initial candidate: %d\n', min_detect_channels);

%% ---------------- FILTER EACH CHANNEL INTO 2-5 Hz ----------------
eeg_2_5_ch = zeros(size(eeg_detect_matrix));

for ch = 1:num_eeg_channels
    sig = eeg_detect_matrix(:, ch);
    sig = sig - mean(sig, 'omitnan');
    eeg_2_5_ch(:, ch) = bandpass(sig, detect_band, Fs);
end

%% ---------------- MOVING EEG POWER AND LINE LENGTH ----------------
power_win_samples = max(1, round(2 * Fs));
power_smooth_samples = max(1, round(1 * Fs));
line_win_samples = max(1, round(1 * Fs));

moving_power_ch = movmean(eeg_2_5_ch.^2, power_win_samples, 1);
moving_power_smooth_ch = movmean(moving_power_ch, power_smooth_samples, 1);

line_length_raw_ch = [zeros(1, num_eeg_channels); abs(diff(eeg_detect_matrix))];
line_length_ch = movmean(line_length_raw_ch, line_win_samples, 1);

%% ---------------- CHANNEL-WISE ROBUST BASELINE THRESHOLDS ----------------
baseline_idx = t > ignore_start_sec;

power_med_ch = median(moving_power_smooth_ch(baseline_idx, :), 1, 'omitnan');
power_mad_ch = mad(moving_power_smooth_ch(baseline_idx, :), 1, 1);

line_med_ch = median(line_length_ch(baseline_idx, :), 1, 'omitnan');
line_mad_ch = mad(line_length_ch(baseline_idx, :), 1, 1);

for ch = 1:num_eeg_channels
    if isnan(power_mad_ch(ch)) || power_mad_ch(ch) == 0
        power_mad_ch(ch) = std(moving_power_smooth_ch(baseline_idx, ch), 'omitnan');
    end
    if isnan(power_mad_ch(ch)) || power_mad_ch(ch) == 0
        power_mad_ch(ch) = eps;
    end

    if isnan(line_mad_ch(ch)) || line_mad_ch(ch) == 0
        line_mad_ch(ch) = std(line_length_ch(baseline_idx, ch), 'omitnan');
    end
    if isnan(line_mad_ch(ch)) || line_mad_ch(ch) == 0
        line_mad_ch(ch) = eps;
    end
end

power_threshold_ch = power_med_ch + threshold_factor * power_mad_ch;
line_threshold_ch = line_med_ch + morphology_threshold_factor * line_mad_ch;

%% ---------------- CHANNEL-WISE ACTIVE FLAGS ----------------
power_active_ch = false(size(moving_power_smooth_ch));
line_active_ch = false(size(line_length_ch));

for ch = 1:num_eeg_channels
    power_active_ch(:, ch) = moving_power_smooth_ch(:, ch) > power_threshold_ch(ch);
    line_active_ch(:, ch) = line_length_ch(:, ch) > line_threshold_ch(ch);
end

power_active_ch(t < ignore_start_sec, :) = false;
line_active_ch(t < ignore_start_sec, :) = false;

% Initial candidate creation is now stricter:
% A channel must show BOTH 2-5 Hz power rise and morphology/line-length rise.
% This reduces smooth delta/theta false positives that only look like 3 Hz power.
candidate_active_ch = power_active_ch & line_active_ch;
active_channel_count = sum(candidate_active_ch, 2);
active_channel_fraction = active_channel_count / num_eeg_channels;
seizure_binary = active_channel_count >= min_detect_channels;
seizure_binary(t < ignore_start_sec) = false;

% Smooth tiny holes / spikes in the detection binary.
% Stricter than before so short noisy bursts do not become events.
seizure_binary = movmean(double(seizure_binary), round(0.75 * Fs)) > 0.55;
seizure_binary(t < ignore_start_sec) = false;

fprintf('EEG-only candidate detection completed.\n');
fprintf('Max active EEG channels at one time: %d / %d\n', ...
    max(active_channel_count), num_eeg_channels);

%% ============================================================
% BLOCK 7: CANDIDATE WINDOW EXTRACTION + CLOSE MERGE
%% ============================================================

fprintf('\nExtracting candidate windows from EEG-only binary signal...\n');

d = diff([false; seizure_binary(:); false]);
start_idx = find(d == 1);
end_idx = find(d == -1) - 1;

raw_candidate_starts = t(start_idx);
raw_candidate_ends = t(end_idx);
raw_candidate_durations = raw_candidate_ends - raw_candidate_starts;

% Keep fragments before merge. Do NOT delete >30 sec fragments here,
% because a prolonged generalized spike-wave run may be clinically important
% even if it is not a normal short typical absence seizure.
valid_raw = raw_candidate_durations >= 1 & raw_candidate_durations <= prolonged_review_max_duration;
raw_candidate_starts = raw_candidate_starts(valid_raw);
raw_candidate_ends = raw_candidate_ends(valid_raw);

candidate_starts = [];
candidate_ends = [];

if ~isempty(raw_candidate_starts)
    [raw_candidate_starts, sort_idx] = sort(raw_candidate_starts);
    raw_candidate_ends = raw_candidate_ends(sort_idx);

    cur_start = raw_candidate_starts(1);
    cur_end = raw_candidate_ends(1);

    for i = 2:length(raw_candidate_starts)
        gap_sec = raw_candidate_starts(i) - cur_end;

        if gap_sec <= merge_gap_sec
            cur_end = max(cur_end, raw_candidate_ends(i));
        else
            candidate_starts(end+1,1) = cur_start;
            candidate_ends(end+1,1) = cur_end;
            cur_start = raw_candidate_starts(i);
            cur_end = raw_candidate_ends(i);
        end
    end

    candidate_starts(end+1,1) = cur_start;
    candidate_ends(end+1,1) = cur_end;
end

candidate_durations = candidate_ends - candidate_starts;
valid_duration_after_merge = candidate_durations >= min_seizure_duration & ...
                             candidate_durations <= prolonged_review_max_duration;

candidate_starts = candidate_starts(valid_duration_after_merge);
candidate_ends = candidate_ends(valid_duration_after_merge);
candidate_durations = candidate_ends - candidate_starts;

fprintf('Raw EEG fragments: %d\n', length(raw_candidate_durations));
fprintf('Candidates after close-merge + duration check: %d\n', length(candidate_starts));
fprintf('Duration logic: 5-30 sec = FINAL possible typical absence; 30-180 sec = PROLONGED REVIEW.\n');

for i = 1:length(candidate_starts)
    fprintf('Candidate %d: %.2f to %.2f sec | Duration %.2f sec\n', ...
        i, candidate_starts(i), candidate_ends(i), candidate_durations(i));
end

raw_candidates = table(candidate_starts(:), candidate_ends(:), candidate_durations(:), ...
    'VariableNames', {'Start_sec','End_sec','Duration_sec'});

raw_candidates_file = fullfile(tables_folder, sprintf('sub_%d_Raw_EEG_Candidates.xlsx', sub_no));
writetable(raw_candidates, raw_candidates_file);

%% ============================================================
% BLOCK 8: EEG-ONLY FINAL VALIDATION
% ECG is NOT used in this block.
%% ============================================================

fprintf('\nValidating candidates using EEG-only morphology + frequency + spread...\n');

Event = [];
Start_sec = [];
End_sec = [];
Duration_sec = [];
Dominant_EEG_Freq_Hz = [];
Spectral_Ratio_2_5Hz = [];
Baseline_Power_Ratio_2_5Hz = [];
Active_Channels = [];
Total_EEG_Channels = [];
Morphology_LineLength_Ratio = [];
Sharpness_Ratio = [];
Rhythmicity_Score = [];
Artifact_Score = [];
Confidence_Score = [];
Confidence_Grade = strings(0,1);
Decision = strings(0,1);
Final_Event_Type = strings(0,1);
Event_Severity = strings(0,1);
Event_Color_Label = strings(0,1);
Validation_Note = strings(0,1);

for i = 1:length(candidate_starts)

    s_sec = candidate_starts(i);
    e_sec = candidate_ends(i);
    dur_sec = e_sec - s_sec;

    idx_event = t >= s_sec & t <= e_sec;

    % 30 sec context window around the candidate for stable validation
    context_half = checking_window_sec / 2;
    context_start = max(0, (s_sec + e_sec)/2 - context_half);
    context_end = min(total_duration, (s_sec + e_sec)/2 + context_half);
    idx_context = t >= context_start & t <= context_end;

    idx_before = t >= max(0, s_sec - before_after_sec) & t < s_sec;
    idx_after = t > e_sec & t <= min(total_duration, e_sec + before_after_sec);
    idx_base = idx_before | idx_after;

    if sum(idx_event) < round(2 * Fs)
        continue;
    end

    if sum(idx_base) < round(3 * Fs)
        idx_base = idx_context & ~idx_event;
    end

    if sum(idx_base) < round(2 * Fs)
        idx_base = idx_event;
    end

    all_dom_freq = nan(num_eeg_channels,1);
    all_spectral_ratio = nan(num_eeg_channels,1);
    all_power_rise = nan(num_eeg_channels,1);
    all_line_ratio = nan(num_eeg_channels,1);
    all_sharpness_ratio = nan(num_eeg_channels,1);
    all_amp_score = nan(num_eeg_channels,1);

    for ch = 1:num_eeg_channels

        x = eeg_detect_matrix(idx_event, ch);
        xb = eeg_detect_matrix(idx_base, ch);

        x = x - mean(x, 'omitnan');
        xb = xb - mean(xb, 'omitnan');

        if length(x) < round(2 * Fs) || all(isnan(x)) || std(x, 'omitnan') == 0
            continue;
        end

        x(isnan(x)) = 0;
        xb(isnan(xb)) = 0;

        nfft = max(512, 2^nextpow2(length(x)));
        win_len = min(length(x), round(4 * Fs));
        if win_len < round(2 * Fs)
            win_len = min(length(x), round(2 * Fs));
        end
        if win_len < 16
            continue;
        end
        overlap_len = floor(win_len / 2);

        [pxx, f] = pwelch(x, hamming(win_len), overlap_len, nfft, Fs);

        base_win_len = min(length(xb), win_len);
        if base_win_len < 16
            xb = x;
            base_win_len = min(length(xb), win_len);
        end
        base_overlap = floor(base_win_len / 2);
        [pb, fb] = pwelch(xb, hamming(base_win_len), base_overlap, nfft, Fs);

        band_2_5 = f >= detect_band(1) & f <= detect_band(2);
        band_05_30 = f >= 0.5 & f <= 30;
        band_core = f >= absence_core_band(1) & f <= absence_core_band(2);
        base_band_2_5 = fb >= detect_band(1) & fb <= detect_band(2);

        power_2_5 = trapz(f(band_2_5), pxx(band_2_5));
        power_05_30 = trapz(f(band_05_30), pxx(band_05_30));
        base_power_2_5 = trapz(fb(base_band_2_5), pb(base_band_2_5));

        if base_power_2_5 <= 0 || isnan(base_power_2_5)
            base_power_2_5 = eps;
        end

        all_spectral_ratio(ch) = power_2_5 / max(power_05_30, eps);
        all_power_rise(ch) = power_2_5 / base_power_2_5;

        if any(band_core)
            [~, max_idx_core] = max(pxx(band_core));
            freq_list_core = f(band_core);
            all_dom_freq(ch) = freq_list_core(max_idx_core);
        elseif any(band_2_5)
            [~, max_idx_broad] = max(pxx(band_2_5));
            freq_list_broad = f(band_2_5);
            all_dom_freq(ch) = freq_list_broad(max_idx_broad);
        end

        line_event = mean(abs(diff(x)), 'omitnan');
        line_base = mean(abs(diff(xb)), 'omitnan');
        if line_base <= 0 || isnan(line_base)
            line_base = eps;
        end
        all_line_ratio(ch) = line_event / line_base;

        sharp_event = std(diff(x), 'omitnan');
        sharp_base = std(diff(xb), 'omitnan');
        if sharp_base <= 0 || isnan(sharp_base)
            sharp_base = eps;
        end
        all_sharpness_ratio(ch) = sharp_event / sharp_base;

        base_amp = median(abs(xb), 'omitnan');
        if base_amp <= 0 || isnan(base_amp)
            base_amp = eps;
        end
        all_amp_score(ch) = max(abs(x)) / base_amp;
    end

    active_flags_final = ...
        all_dom_freq >= absence_core_band(1) & all_dom_freq <= absence_core_band(2) & ...
        all_power_rise >= min_power_rise_final & ...
        all_spectral_ratio >= min_spectral_ratio_final & ...
        all_line_ratio >= min_line_length_ratio_final & ...
        all_sharpness_ratio >= min_sharpness_ratio_final;

    active_flags_review = ...
        all_dom_freq >= detect_band(1) & all_dom_freq <= detect_band(2) & ...
        all_power_rise >= min_power_rise_review & ...
        all_spectral_ratio >= min_spectral_ratio_review & ...
        all_line_ratio >= min_line_length_ratio_review & ...
        all_sharpness_ratio >= min_sharpness_ratio_review;

    active_channels_final = sum(active_flags_final);
    active_channels_review = sum(active_flags_review);

    if active_channels_final > 0
        metric_idx = active_flags_final;
    elseif active_channels_review > 0
        metric_idx = active_flags_review;
    else
        metric_idx = isfinite(all_dom_freq);
    end

    if ~any(metric_idx)
        metric_idx = true(num_eeg_channels,1);
    end

    dominant_freq = median(all_dom_freq(metric_idx), 'omitnan');
    spectral_ratio = median(all_spectral_ratio(metric_idx), 'omitnan');
    power_rise = median(all_power_rise(metric_idx), 'omitnan');
    line_ratio = median(all_line_ratio(metric_idx), 'omitnan');
    sharpness_ratio = median(all_sharpness_ratio(metric_idx), 'omitnan');
    amp_score = median(all_amp_score(metric_idx), 'omitnan');

    if isnan(dominant_freq); dominant_freq = 0; end
    if isnan(spectral_ratio); spectral_ratio = 0; end
    if isnan(power_rise); power_rise = 0; end
    if isnan(line_ratio); line_ratio = 0; end
    if isnan(sharpness_ratio); sharpness_ratio = 0; end
    if isnan(amp_score); amp_score = Inf; end

    final_channel_fraction = active_channels_final / num_eeg_channels;
    review_channel_fraction = active_channels_review / num_eeg_channels;

    typical_duration_ok = dur_sec >= min_seizure_duration && dur_sec <= typical_max_seizure_duration;
    prolonged_duration_ok = dur_sec > typical_max_seizure_duration && dur_sec <= prolonged_review_max_duration;
    duration_ok = typical_duration_ok || prolonged_duration_ok;
    artifact_ok = amp_score <= max_artifact_amp_score;

    freq_final_ok = dominant_freq >= absence_core_band(1) && dominant_freq <= absence_core_band(2);
    freq_review_ok = dominant_freq >= detect_band(1) && dominant_freq <= detect_band(2);

    final_ok = typical_duration_ok && artifact_ok && freq_final_ok && ...
               power_rise >= min_power_rise_final && ...
               spectral_ratio >= min_spectral_ratio_final && ...
               line_ratio >= min_line_length_ratio_final && ...
               sharpness_ratio >= min_sharpness_ratio_final && ...
               final_channel_fraction >= min_final_channel_fraction;

    rescue_ok = typical_duration_ok && artifact_ok && freq_review_ok && ...
                power_rise >= (min_power_rise_final + 1.0) && ...
                spectral_ratio >= min_spectral_ratio_review && ...
                line_ratio >= (min_line_length_ratio_final + 0.15) && ...
                sharpness_ratio >= min_sharpness_ratio_final && ...
                review_channel_fraction >= 0.60;

    prolonged_review_ok = prolonged_duration_ok && artifact_ok && freq_review_ok && ...
                power_rise >= min_power_rise_review && ...
                spectral_ratio >= min_spectral_ratio_review && ...
                line_ratio >= min_line_length_ratio_review && ...
                sharpness_ratio >= min_sharpness_ratio_review && ...
                review_channel_fraction >= min_review_channel_fraction;

    review_ok = duration_ok && artifact_ok && freq_review_ok && ...
                power_rise >= min_power_rise_review && ...
                spectral_ratio >= min_spectral_ratio_review && ...
                line_ratio >= min_line_length_ratio_review && ...
                sharpness_ratio >= min_sharpness_ratio_review && ...
                review_channel_fraction >= min_review_channel_fraction;

    % Rhythmicity score: high when 2-5 Hz power is concentrated and similar across channels
    freq_score = 1 - min(abs(dominant_freq - 3) / 2.5, 1);
    spread_score = max(final_channel_fraction, review_channel_fraction);
    power_score = min(power_rise / 8, 1);
    ratio_score = min(spectral_ratio / 0.45, 1);
    morphology_score = min(line_ratio / 2.0, 1);
    artifact_penalty = min(amp_score / max_artifact_amp_score, 1);

    rhythmicity_score = max(0, min(1, 0.60 * ratio_score + 0.40 * freq_score));

    confidence = 100 * (0.25 * freq_score + ...
                        0.25 * spread_score + ...
                        0.20 * power_score + ...
                        0.15 * ratio_score + ...
                        0.15 * morphology_score) - 15 * artifact_penalty;

    confidence = max(0, min(100, confidence));
    confidence_grade = getConfidenceGrade(confidence, high_confidence_cutoff, medium_confidence_cutoff);

    if final_ok
        decision_text = "LIKELY TYPICAL ABSENCE-LIKE EEG EVENT";
        final_type = "FINAL";
    elseif rescue_ok
        decision_text = "LIKELY TYPICAL ABSENCE-LIKE EEG EVENT - RESCUE";
        final_type = "FINAL";
    elseif prolonged_review_ok
        decision_text = "PROLONGED GENERALIZED SPIKE-WAVE / ABSENCE-LIKE ACTIVITY - REVIEW";
        final_type = "REVIEW";
    elseif review_ok
        decision_text = "WEAK / SUSPICIOUS EEG EVENT - REVIEW";
        final_type = "REVIEW";
    else
        decision_text = "REJECTED / LIKELY ARTIFACT OR NON-SEIZURE RHYTHM";
        final_type = "REJECTED";
    end

    %% ------------------------------------------------------------
    % COLOR / SEVERITY MARKING
    % This is for viewer + screenshots + PDF, not a new detector.
    % RED    = very possible / likely EEG event
    % YELLOW = suspicious review-needed event
    % GREEN  = weak / low-confidence review event
    %% ------------------------------------------------------------
    if final_type == "FINAL"
        event_severity = "VERY POSSIBLE / LIKELY EEG EVENT";
        event_color_label = "RED";

    elseif final_type == "REVIEW"
        if contains(decision_text, "PROLONGED") && confidence >= red_review_confidence_cutoff
            event_severity = "VERY POSSIBLE BUT PROLONGED - REVIEW";
            event_color_label = "RED";
        elseif confidence >= yellow_review_confidence_cutoff
            event_severity = "SUSPICIOUS EEG EVENT - REVIEW";
            event_color_label = "YELLOW";
        else
            event_severity = "WEAK POSSIBILITY / LOW-CONFIDENCE REVIEW";
            event_color_label = "GREEN";
        end

    else
        event_severity = "REJECTED";
        event_color_label = "GRAY";
    end

    note_text = sprintf(['EEG-only: %.2f Hz, %.2fx 2-5Hz power rise, ', ...
        'spectral ratio %.2f, line ratio %.2f, sharpness %.2f, active final %d/%d, active review %d/%d'], ...
        dominant_freq, power_rise, spectral_ratio, line_ratio, sharpness_ratio, ...
        active_channels_final, num_eeg_channels, active_channels_review, num_eeg_channels);

    Event(end+1,1) = i;
    Start_sec(end+1,1) = s_sec;
    End_sec(end+1,1) = e_sec;
    Duration_sec(end+1,1) = dur_sec;
    Dominant_EEG_Freq_Hz(end+1,1) = dominant_freq;
    Spectral_Ratio_2_5Hz(end+1,1) = spectral_ratio;
    Baseline_Power_Ratio_2_5Hz(end+1,1) = power_rise;
    Active_Channels(end+1,1) = max(active_channels_final, active_channels_review);
    Total_EEG_Channels(end+1,1) = num_eeg_channels;
    Morphology_LineLength_Ratio(end+1,1) = line_ratio;
    Sharpness_Ratio(end+1,1) = sharpness_ratio;
    Rhythmicity_Score(end+1,1) = rhythmicity_score;
    Artifact_Score(end+1,1) = amp_score;
    Confidence_Score(end+1,1) = confidence;
    Confidence_Grade(end+1,1) = confidence_grade;
    Decision(end+1,1) = decision_text;
    Final_Event_Type(end+1,1) = final_type;
    Event_Severity(end+1,1) = event_severity;
    Event_Color_Label(end+1,1) = event_color_label;
    Validation_Note(end+1,1) = string(note_text);
end

all_validated_events = table( ...
    Event, Start_sec, End_sec, Duration_sec, Dominant_EEG_Freq_Hz, ...
    Spectral_Ratio_2_5Hz, Baseline_Power_Ratio_2_5Hz, ...
    Active_Channels, Total_EEG_Channels, Morphology_LineLength_Ratio, ...
    Sharpness_Ratio, Rhythmicity_Score, Artifact_Score, ...
    Confidence_Score, Confidence_Grade, Decision, Final_Event_Type, ...
    Event_Severity, Event_Color_Label, Validation_Note);

if isempty(all_validated_events)
    final_events = table();
    review_events = table();
    rejected_events = table();
else
    final_events = all_validated_events(all_validated_events.Final_Event_Type == "FINAL", :);
    review_events = all_validated_events(all_validated_events.Final_Event_Type == "REVIEW", :);
    rejected_events = all_validated_events(all_validated_events.Final_Event_Type == "REJECTED", :);
end

kept_events = [final_events; review_events];
kept_events_before_competition = kept_events;

if ~isempty(kept_events)
    kept_events = sortrows(kept_events, 'Start_sec');

    %% ------------------------------------------------------------
    % 60-SECOND COMPETITION CLEANUP
    % If two possible detections happen close together, keep only the
    % strongest one. Strength is based on confidence + FINAL priority +
    % EEG power, spectral purity, and morphology support.
    %% ------------------------------------------------------------

    keep_competition = false(height(kept_events), 1);
    i_comp = 1;

    while i_comp <= height(kept_events)

        cluster_idx = i_comp;
        cluster_end = kept_events.End_sec(i_comp);
        j_comp = i_comp + 1;

        while j_comp <= height(kept_events) && ...
                kept_events.Start_sec(j_comp) - cluster_end <= event_competition_sec

            cluster_idx(end+1) = j_comp; %#ok<SAGROW>
            cluster_end = max(cluster_end, kept_events.End_sec(j_comp));
            j_comp = j_comp + 1;
        end

        cluster_idx = cluster_idx(:);

        confidence_part = kept_events.Confidence_Score(cluster_idx);
        confidence_part(~isfinite(confidence_part)) = 0;

        final_bonus = 15 * double(string(kept_events.Final_Event_Type(cluster_idx)) == "FINAL");
        power_part = 3 * kept_events.Baseline_Power_Ratio_2_5Hz(cluster_idx);
        purity_part = 20 * kept_events.Spectral_Ratio_2_5Hz(cluster_idx);
        morphology_part = 5 * kept_events.Morphology_LineLength_Ratio(cluster_idx);

        final_bonus = final_bonus(:);
        power_part = power_part(:);
        purity_part = purity_part(:);
        morphology_part = morphology_part(:);

        event_strength_score = confidence_part + final_bonus + power_part + purity_part + morphology_part;
        event_strength_score(~isfinite(event_strength_score)) = 0;

        [~, best_local_idx] = max(event_strength_score);
        keep_competition(cluster_idx(best_local_idx)) = true;

        i_comp = j_comp;
    end

    kept_events = kept_events(keep_competition, :);
    kept_events = sortrows(kept_events, 'Start_sec');
    kept_events.Event = (1:height(kept_events))';

    final_events = kept_events(string(kept_events.Final_Event_Type) == "FINAL", :);
    review_events = kept_events(string(kept_events.Final_Event_Type) == "REVIEW", :);
end

competition_events_file = fullfile(tables_folder, sprintf('sub_%d_Kept_Events_After_60sec_Competition.xlsx', sub_no));
if ~isempty(kept_events)
    writetable(kept_events, competition_events_file);
else
    no_competition_events = table("NO EVENT", 'VariableNames', {'Status'});
    writetable(no_competition_events, competition_events_file);
end

if isempty(kept_events)
    seizure_starts = [];
    seizure_ends = [];
    seizure_durations = [];
    event_status = strings(0,1);
    event_color_status = strings(0,1);
else
    seizure_starts = kept_events.Start_sec;
    seizure_ends = kept_events.End_sec;
    seizure_durations = kept_events.Duration_sec;
    event_status = kept_events.Final_Event_Type;
    event_color_status = kept_events.Event_Color_Label;
end

validated_events_file = fullfile(tables_folder, sprintf('sub_%d_All_EEG_Validated_Events.xlsx', sub_no));
writetable(all_validated_events, validated_events_file);

fprintf('\n================ EEG-ONLY VALIDATION SUMMARY ================\n');
fprintf('Final likely EEG events: %d\n', height(final_events));
fprintf('Review-needed EEG events: %d\n', height(review_events));
fprintf('Rejected EEG candidates: %d\n', height(rejected_events));
fprintf('Screenshots/report will include FINAL + REVIEW windows after 60-sec cleanup: %d\n', height(kept_events));
disp(kept_events);
fprintf('==============================================================\n');


%% ============================================================
% BLOCK 8.5: CLEAN SELECTED ECG ONLY INSIDE EEG-DETECTED EVENT WINDOWS
% This does NOT affect seizure detection.
% This does NOT average ECG channels.
% It uses the selected best ECG channel only.
%
% Method:
% - Build an EEG leakage template during the event window.
% - Regress that leakage template out of the selected ECG only inside
%   the detected event period.
% - Before/after ECG remains unchanged.
%% ============================================================

ecg_display_clean = ecg_display;
ecg_filt_clean = ecg_filt;

ECG_Clean_Event = [];
ECG_Clean_Start_sec = [];
ECG_Clean_End_sec = [];
ECG_Clean_Corr_Before = [];
ECG_Clean_Corr_After = [];
ECG_HRV_Clean_Accepted = [];
ECG_Clean_Note = strings(0,1);

if has_ecg && exist('kept_events', 'var') && ~isempty(kept_events)

    fprintf('\nCleaning selected ECG only inside EEG-detected event windows...\n');

    for s = 1:height(kept_events)

        sz_start = kept_events.Start_sec(s);
        sz_end = kept_events.End_sec(s);

        idx_event = t >= sz_start & t <= sz_end;

        if sum(idx_event) < round(2 * Fs)
            continue;
        end

        [clean_display_seg, clean_filt_seg, corr_before, corr_after, hrv_clean_ok, clean_note] = ...
            cleanECGOnlyDuringEvent( ...
            ecg_display, ...
            ecg_filt, ...
            eeg_detect_matrix, ...
            t, ...
            Fs, ...
            sz_start, ...
            sz_end);

        ecg_display_clean(idx_event) = clean_display_seg;
        ecg_filt_clean(idx_event) = clean_filt_seg;

        ECG_Clean_Event(end+1,1) = s;
        ECG_Clean_Start_sec(end+1,1) = sz_start;
        ECG_Clean_End_sec(end+1,1) = sz_end;
        ECG_Clean_Corr_Before(end+1,1) = corr_before;
        ECG_Clean_Corr_After(end+1,1) = corr_after;
        ECG_HRV_Clean_Accepted(end+1,1) = hrv_clean_ok;
        ECG_Clean_Note(end+1,1) = clean_note;

        fprintf('Event %d ECG clean: %.2f-%.2f sec | corr %.3f -> %.3f | %s\n', ...
            s, sz_start, sz_end, corr_before, corr_after, char(clean_note));
    end

else
    fprintf('\nECG event cleaning skipped: no ECG or no kept EEG events.\n');
end

ecg_cleaning_table = table( ...
    ECG_Clean_Event, ECG_Clean_Start_sec, ECG_Clean_End_sec, ...
    ECG_Clean_Corr_Before, ECG_Clean_Corr_After, ...
    ECG_HRV_Clean_Accepted, ECG_Clean_Note);

ecg_cleaning_file = fullfile(tables_folder, sprintf('sub_%d_ECG_Event_Window_Cleaning.xlsx', sub_no));

if ~isempty(ecg_cleaning_table)
    writetable(ecg_cleaning_table, ecg_cleaning_file);
else
    empty_ecg_cleaning = table("NO ECG CLEANING DONE", 'VariableNames', {'Status'});
    writetable(empty_ecg_cleaning, ecg_cleaning_file);
end

fprintf('Saved ECG event-window cleaning table: %s\n', ecg_cleaning_file);




%% ============================================================
% BLOCK 9: RESULT TABLE GENERATION
% Excel keeps EEG metrics + ECG/HRV AFTER detection.
% ECG is not used for detection decisions.
%
% Important ECG rule:
% - HR before/after uses selected best ECG filtered signal.
% - HR during event uses ecg_filt_clean.
% - ecg_filt_clean is only changed inside EEG-detected event windows.
%% ============================================================

if isempty(kept_events)
    patient_result = table();

    patient_result.Subject = sub_no;
    patient_result.Event = 0;
    patient_result.Start_sec = NaN;
    patient_result.End_sec = NaN;
    patient_result.Duration_sec = NaN;
    patient_result.Event_Status = "NO EVENT";
    patient_result.Event_Severity = "NO EVENT";
    patient_result.Event_Color_Label = "NONE";
    patient_result.Final_Event_Type = "NO EVENT DETECTED";
    patient_result.Dominant_EEG_Freq_Hz = NaN;
    patient_result.Spectral_Ratio_2_5Hz = NaN;
    patient_result.Baseline_Power_Ratio_2_5Hz = NaN;
    patient_result.Active_Channels = 0;
    patient_result.Total_EEG_Channels = num_eeg_channels;
    patient_result.Morphology_LineLength_Ratio = NaN;
    patient_result.Sharpness_Ratio = NaN;
    patient_result.Rhythmicity_Score = NaN;
    patient_result.Artifact_Score = NaN;
    patient_result.Confidence_Score = NaN;
    patient_result.Confidence_Grade = "NO EVENT";
    patient_result.Decision = "NO EVENT DETECTED";
    patient_result.Validation_Note = "No EEG-only event passed final/review rules";

    patient_result.HR_Before_bpm = NaN;
    patient_result.HR_During_bpm = NaN;
    patient_result.HR_After_bpm = NaN;
    patient_result.SDNN_Before_ms = NaN;
    patient_result.SDNN_During_ms = NaN;
    patient_result.SDNN_After_ms = NaN;
    patient_result.RMSSD_Before_ms = NaN;
    patient_result.RMSSD_During_ms = NaN;
    patient_result.RMSSD_After_ms = NaN;
    patient_result.RPeaks_Before = 0;
    patient_result.RPeaks_During = 0;
    patient_result.RPeaks_After = 0;
    patient_result.HRV_Label = "NO EVENT";
    patient_result.EEG_ECG_Correlation_During = NaN;
    patient_result.ECG_Selected_Channel = "NO EVENT";
    patient_result.ECG_Note = "Best single ECG/EKG selection done if ECG existed; ECG not used for detection";

else
    n_events = height(kept_events);

    HR_Before_bpm = nan(n_events,1);
    HR_During_bpm = nan(n_events,1);
    HR_After_bpm = nan(n_events,1);
    SDNN_Before_ms = nan(n_events,1);
    SDNN_During_ms = nan(n_events,1);
    SDNN_After_ms = nan(n_events,1);
    RMSSD_Before_ms = nan(n_events,1);
    RMSSD_During_ms = nan(n_events,1);
    RMSSD_After_ms = nan(n_events,1);
    RPeaks_Before = zeros(n_events,1);
    RPeaks_During = zeros(n_events,1);
    RPeaks_After = zeros(n_events,1);
    HRV_Label = strings(n_events,1);
    EEG_ECG_Correlation_During = nan(n_events,1);

    if has_ecg
        selected_ecg_label = string(labels(ecg_channel));
    else
        selected_ecg_label = "NO ECG";
    end

    ECG_Selected_Channel = repmat(selected_ecg_label, n_events, 1);
    ECG_Note = repmat("Best single ECG/EKG selected; ECG not used for detection; during-event ECG cleaned only after EEG detection", n_events, 1);

    for s = 1:n_events

        sz_start = kept_events.Start_sec(s);
        sz_end = kept_events.End_sec(s);

        before_idx = t >= max(0, sz_start-before_after_sec) & t < sz_start;
        during_idx = t >= sz_start & t <= sz_end;
        after_idx = t > sz_end & t <= min(total_duration, sz_end+before_after_sec);

        if has_ecg
            % Before and after: selected best ECG filtered signal.
            [HR_Before_bpm(s), SDNN_Before_ms(s), RMSSD_Before_ms(s), RPeaks_Before(s)] = ...
                get_hrv(ecg_filt(before_idx), Fs);

            [HR_After_bpm(s), SDNN_After_ms(s), RMSSD_After_ms(s), RPeaks_After(s)] = ...
                get_hrv(ecg_filt(after_idx), Fs);

            % During event: cleaned selected ECG filtered signal.
            % This cleaning happens only after EEG event detection.
            [HR_During_bpm(s), SDNN_During_ms(s), RMSSD_During_ms(s), RPeaks_During(s)] = ...
                get_hrv(ecg_filt_clean(during_idx), Fs);

            % Correlation is only a contamination warning.
            % It does NOT change Final_Event_Type or Decision.
            eeg_during = median(eeg_detect_matrix(during_idx, :), 2, 'omitnan');
            ecg_during = ecg_filt_clean(during_idx);

            min_corr_len = min(length(eeg_during), length(ecg_during));

            if min_corr_len > Fs
                EEG_ECG_Correlation_During(s) = corr(eeg_during(1:min_corr_len), ...
                    ecg_during(1:min_corr_len), 'Rows', 'complete');
            else
                EEG_ECG_Correlation_During(s) = NaN;
            end

            hrv_before_mean = mean([SDNN_Before_ms(s), RMSSD_Before_ms(s)], 'omitnan');
            hrv_during_mean = mean([SDNN_During_ms(s), RMSSD_During_ms(s)], 'omitnan');

            if isnan(hrv_before_mean) || isnan(hrv_during_mean) || hrv_before_mean == 0
                HRV_Label(s) = "HRV NOT RELIABLE";
            else
                hrv_change_ratio = hrv_during_mean / hrv_before_mean;

                if hrv_change_ratio >= 1.5
                    HRV_Label(s) = "HRV INCREASED";
                elseif hrv_change_ratio <= 0.67
                    HRV_Label(s) = "HRV DECREASED";
                else
                    HRV_Label(s) = "HRV NO MAJOR CHANGE";
                end
            end
        else
            HRV_Label(s) = "NO ECG";
            ECG_Note(s) = "No ECG/EKG channel found; ECG not used for detection";
            ECG_Selected_Channel(s) = "NO ECG";
        end
    end

    patient_result = table();
    patient_result.Subject = repmat(sub_no, n_events, 1);
    patient_result.Event = kept_events.Event;
    patient_result.Start_sec = kept_events.Start_sec;
    patient_result.End_sec = kept_events.End_sec;
    patient_result.Duration_sec = kept_events.Duration_sec;
    patient_result.Event_Status = kept_events.Final_Event_Type;
    patient_result.Event_Severity = kept_events.Event_Severity;
    patient_result.Event_Color_Label = kept_events.Event_Color_Label;
    patient_result.Final_Event_Type = kept_events.Decision;
    patient_result.Dominant_EEG_Freq_Hz = kept_events.Dominant_EEG_Freq_Hz;
    patient_result.Spectral_Ratio_2_5Hz = kept_events.Spectral_Ratio_2_5Hz;
    patient_result.Baseline_Power_Ratio_2_5Hz = kept_events.Baseline_Power_Ratio_2_5Hz;
    patient_result.Active_Channels = kept_events.Active_Channels;
    patient_result.Total_EEG_Channels = kept_events.Total_EEG_Channels;
    patient_result.Morphology_LineLength_Ratio = kept_events.Morphology_LineLength_Ratio;
    patient_result.Sharpness_Ratio = kept_events.Sharpness_Ratio;
    patient_result.Rhythmicity_Score = kept_events.Rhythmicity_Score;
    patient_result.Artifact_Score = kept_events.Artifact_Score;
    patient_result.Confidence_Score = kept_events.Confidence_Score;
    patient_result.Confidence_Grade = kept_events.Confidence_Grade;
    patient_result.Decision = kept_events.Decision;
    patient_result.Validation_Note = kept_events.Validation_Note;

    patient_result.HR_Before_bpm = HR_Before_bpm;
    patient_result.HR_During_bpm = HR_During_bpm;
    patient_result.HR_After_bpm = HR_After_bpm;
    patient_result.SDNN_Before_ms = SDNN_Before_ms;
    patient_result.SDNN_During_ms = SDNN_During_ms;
    patient_result.SDNN_After_ms = SDNN_After_ms;
    patient_result.RMSSD_Before_ms = RMSSD_Before_ms;
    patient_result.RMSSD_During_ms = RMSSD_During_ms;
    patient_result.RMSSD_After_ms = RMSSD_After_ms;
    patient_result.RPeaks_Before = RPeaks_Before;
    patient_result.RPeaks_During = RPeaks_During;
    patient_result.RPeaks_After = RPeaks_After;
    patient_result.HRV_Label = HRV_Label;
    patient_result.EEG_ECG_Correlation_During = EEG_ECG_Correlation_During;
    patient_result.ECG_Selected_Channel = ECG_Selected_Channel;
    patient_result.ECG_Note = ECG_Note;
end

disp(patient_result);

%% ============================================================
% BLOCK 10: SAVE TABLES
%% ============================================================

subject_excel_file = fullfile(tables_folder, sprintf('sub_%d_EEG_ONLY_Seizure_Summary.xlsx', sub_no));
subject_csv_file = fullfile(tables_folder, sprintf('sub_%d_EEG_ONLY_Seizure_Summary.csv', sub_no));

writetable(patient_result, subject_excel_file);
writetable(patient_result, subject_csv_file);

combined_csv_file = fullfile(main_output_folder, 'Combined_EEG_ONLY_Seizure_Summary.csv');
combined_excel_file = fullfile(main_output_folder, 'Combined_EEG_ONLY_Seizure_Summary.xlsx');

if isfile(combined_csv_file)
    old_summary = readtable(combined_csv_file);
    old_vars = string(old_summary.Properties.VariableNames);
    new_vars = string(patient_result.Properties.VariableNames);

    if isequal(old_vars, new_vars)
        if ~isempty(old_summary) && any(strcmp(old_summary.Properties.VariableNames, 'Subject'))
            old_summary = old_summary(old_summary.Subject ~= sub_no, :);
        end
        final_combined = [old_summary; patient_result];
    else
        warning('Old combined summary has different columns. Creating fresh combined summary.');
        final_combined = patient_result;
    end
else
    final_combined = patient_result;
end

writetable(final_combined, combined_csv_file);
writetable(final_combined, combined_excel_file);

fprintf('\nSaved subject Excel: %s\n', subject_excel_file);
fprintf('Saved subject CSV: %s\n', subject_csv_file);
fprintf('Updated combined CSV: %s\n', combined_csv_file);
fprintf('Updated combined Excel: %s\n', combined_excel_file);

%% ============================================================
% BLOCK 11: TEXT REPORT + PIPELINE EXPLANATION
%% ============================================================

report_file = fullfile(reports_folder, sprintf('sub_%d_Report.txt', sub_no));
pipeline_file = fullfile(pipeline_folder, sprintf('sub_%d_Pipeline_Flow.txt', sub_no));

fid = fopen(report_file, 'w');

fprintf(fid, 'EEG-ONLY MULTI-CHANNEL ABSENCE-SEIZURE-LIKE EVENT REPORT\n');
fprintf(fid, '=======================================================\n\n');
fprintf(fid, 'Subject: sub_%d\n', sub_no);
fprintf(fid, 'EDF file: %s\n', filename);
fprintf(fid, 'Total duration: %.2f sec / %.2f min\n', total_duration, total_duration/60);
fprintf(fid, 'Sampling rate used: %.2f Hz\n', Fs);
fprintf(fid, 'EEG channels used after cleanup: %d\n', length(eeg_channels));
fprintf(fid, 'EEG reference/montage mode: %s\n', montage_note);

if has_ecg
    fprintf(fid, 'Selected ECG/EKG channel for HRV/report only: %s\n', char(labels(ecg_channel)));
else
    fprintf(fid, 'Selected ECG/EKG channel: Not found\n');
end

fprintf(fid, '\nIMPORTANT DETECTION RULE:\n');
fprintf(fid, 'Seizure-like event detection is based on EEG only.\n');
fprintf(fid, 'ECG is used only after EEG detection for HR, SDNN, RMSSD, and visual checking.\n\n');

fprintf(fid, 'EEG filter band: %.1f-%.1f Hz\n', eeg_filter_band(1), eeg_filter_band(2));
fprintf(fid, 'Detection band: %.1f-%.1f Hz\n', detect_band(1), detect_band(2));
fprintf(fid, 'Typical absence core band: %.1f-%.1f Hz\n', absence_core_band(1), absence_core_band(2));
fprintf(fid, 'Checking context window: %.1f sec\n', checking_window_sec);
fprintf(fid, 'Close-fragment merge gap: %.1f sec\n', merge_gap_sec);
fprintf(fid, 'Duration rule: %.1f-%.1f sec FINAL typical; %.1f-%.1f sec prolonged REVIEW\n', min_seizure_duration, typical_max_seizure_duration, typical_max_seizure_duration, prolonged_review_max_duration);

fprintf(fid, '\nEvents included in report: %d\n', height(kept_events));
red_event_count = sum(string(event_color_status) == "RED");
yellow_event_count = sum(string(event_color_status) == "YELLOW");
green_event_count = sum(string(event_color_status) == "GREEN");
fprintf(fid, 'Final likely events: %d\n', height(final_events));
fprintf(fid, 'Review suspicious events: %d\n', height(review_events));
fprintf(fid, 'RED very possible windows: %d\n', red_event_count);
fprintf(fid, 'YELLOW suspicious review windows: %d\n', yellow_event_count);
fprintf(fid, 'GREEN weak review windows: %d\n\n', green_event_count);

for s = 1:height(kept_events)
    fprintf(fid, 'Event %d\n', s);
    fprintf(fid, 'Status: %s\n', kept_events.Final_Event_Type(s));
    fprintf(fid, 'Severity / marking: %s (%s)\n', kept_events.Event_Severity(s), kept_events.Event_Color_Label(s));
    fprintf(fid, 'Start: %.2f sec\n', kept_events.Start_sec(s));
    fprintf(fid, 'End: %.2f sec\n', kept_events.End_sec(s));
    fprintf(fid, 'Duration: %.2f sec\n', kept_events.Duration_sec(s));
    fprintf(fid, 'Dominant EEG frequency: %.2f Hz\n', kept_events.Dominant_EEG_Freq_Hz(s));
    fprintf(fid, 'Spectral ratio 2-5 Hz: %.3f\n', kept_events.Spectral_Ratio_2_5Hz(s));
    fprintf(fid, '2-5 Hz power rise: %.2fx\n', kept_events.Baseline_Power_Ratio_2_5Hz(s));
    fprintf(fid, 'Active channels: %d / %d\n', kept_events.Active_Channels(s), kept_events.Total_EEG_Channels(s));
    fprintf(fid, 'Line-length morphology ratio: %.2f\n', kept_events.Morphology_LineLength_Ratio(s));
    fprintf(fid, 'Confidence: %.1f (%s)\n', kept_events.Confidence_Score(s), kept_events.Confidence_Grade(s));
    fprintf(fid, 'Decision: %s\n', kept_events.Decision(s));
    fprintf(fid, 'Validation note: %s\n\n', kept_events.Validation_Note(s));
end

fprintf(fid, 'CONCEPT REFERENCES USED FOR RULE DESIGN:\n');
fprintf(fid, '- Typical absence EEG is based on generalized spike-wave activity, often around 3 Hz.\n');
fprintf(fid, '- Duration rule follows the usual brief absence-seizure window, commonly around 4-30 sec.\n');
fprintf(fid, '- Multi-channel spread is used because absence activity is usually generalized / bilateral synchronous.\n');
fprintf(fid, '- Line-length / sharpness is added so smooth delta/theta rhythm is not mistaken only because it is near 3 Hz.\n\n');

fprintf(fid, 'NOTE: This is signal-analysis classification only, not clinical diagnosis.\n');
fclose(fid);

fid2 = fopen(pipeline_file, 'w');
fprintf(fid2, 'STRUCTURED PIPELINE FLOW\n');
fprintf(fid2, '========================\n\n');
fprintf(fid2, '1. EDF INPUT\n');
fprintf(fid2, '   EDF file -> labels + signal table + EDF metadata\n\n');
fprintf(fid2, '2. CHANNEL DETECTION\n');
fprintf(fid2, '   Labels -> EEG channels for detection\n');
fprintf(fid2, '   Labels -> ECG/EKG channels for post-detection HR/HRV only\n\n');
fprintf(fid2, '3. SAMPLING NORMALIZATION\n');
fprintf(fid2, '   Each EEG/ECG channel -> resampled to universal Fs\n\n');
fprintf(fid2, '4. EEG PREPROCESSING\n');
fprintf(fid2, '   Raw EEG -> mean removal -> 50 Hz notch -> 0.5-30 Hz bandpass\n\n');
fprintf(fid2, '5. EEG QUALITY CLEANUP\n');
fprintf(fid2, '   Cleaned EEG -> remove flat/static/unusable channels -> usable EEG matrix\n\n');
fprintf(fid2, '6. OPTIONAL EEG REFERENCE / MONTAGE\n');
fprintf(fid2, '   Default AS_RECORDED -> preserves generalized synchronous activity\n');
fprintf(fid2, '   Optional COMMON_AVERAGE -> only if supervisor asks\n\n');
fprintf(fid2, '7. EEG-ONLY CANDIDATE CREATION\n');
fprintf(fid2, '   Usable EEG -> 2-5 Hz filter per channel -> moving power -> robust MAD threshold\n');
fprintf(fid2, '   Multi-channel vote -> initial candidate binary\n\n');
fprintf(fid2, '8. CANDIDATE MERGE\n');
fprintf(fid2, '   Close fragments within %.1f sec -> merged event window\n', merge_gap_sec);
fprintf(fid2, '   Merged windows -> 5-30 sec FINAL typical, 30-180 sec prolonged REVIEW\n\n');
fprintf(fid2, '9. EEG-ONLY VALIDATION\n');
fprintf(fid2, '   Candidate + %.1f sec context -> dominant frequency + spectral ratio + power rise + channel spread + line-length + sharpness morphology\n', checking_window_sec);
fprintf(fid2, '   Final / Review / Rejected label generated from EEG only\n\n');
fprintf(fid2, '10. ECG POST-DETECTION ONLY\n');
fprintf(fid2, '   EEG event window -> same time ECG segment -> HR, SDNN, RMSSD\n');
fprintf(fid2, '   ECG values do not change event decision\n\n');
fprintf(fid2, '11. OUTPUTS\n');
fprintf(fid2, '   Excel/CSV tables + text report + all-channel screenshots + graph-only PDF + marked interactive viewer\n');
fclose(fid2);

%% ---------------- STRUCTURED PIPELINE TABLE + FLOW DIAGRAM ----------------
Step_No = (1:11)';
Block_Name = [
    "EDF input"
    "Channel detection"
    "Sampling normalization"
    "EEG preprocessing"
    "EEG quality cleanup"
    "Reference / montage"
    "EEG-only candidate creation"
    "Candidate merge"
    "EEG-only validation"
    "ECG post-detection HRV"
    "Outputs"
];
Input_Data = [
    "EDF file"
    "EDF labels + metadata"
    "Raw EEG/ECG channels"
    "Resampled EEG"
    "Filtered EEG matrix"
    "Usable EEG matrix"
    "Final EEG matrix"
    "Binary candidate regions"
    "Merged candidate windows + 30 sec context"
    "Kept EEG windows + ECG signal"
    "All calculated tables + figures"
];
Process = [
    "Read EDF using edfread/edfinfo"
    "Auto-detect EEG and ECG/EKG by labels"
    "Resample all channels to universal Fs"
    "Mean removal + 50 Hz notch + 0.5-30 Hz bandpass"
    "Remove flat/static/sine-like bad EEG channels"
    "Keep as-recorded by default; optional common average"
    "2-5 Hz power + line-length morphology + multi-channel vote"
    "Merge close fragments before duration check"
    "Check frequency, power rise, spectral ratio, spread, morphology, artifact score"
    "Calculate HR, SDNN, RMSSD after EEG event is already found"
    "Save Excel/CSV, screenshots, PDF, text report, viewer"
];
Output_Data = [
    "data + info + labels"
    "eeg_channels + ecg_channels"
    "Fs + aligned signals"
    "eeg_matrix"
    "clean eeg_matrix + channel quality table"
    "eeg_detect_matrix"
    "seizure_binary + raw_candidates"
    "candidate_starts + candidate_ends"
    "kept_events with RED/YELLOW/GREEN marking"
    "patient_result HRV columns"
    "final report folder"
];
Used_As_Input_For = [
    "Channel detection"
    "Sampling normalization"
    "Preprocessing"
    "Quality cleanup"
    "Reference / montage"
    "Candidate creation"
    "Candidate merge"
    "EEG-only validation"
    "ECG post-detection + plots + Excel"
    "Excel/PDF/screenshots"
    "Manual review / paper presentation"
];

pipeline_table = table(Step_No, Block_Name, Input_Data, Process, Output_Data, Used_As_Input_For);
pipeline_table_xlsx = fullfile(pipeline_folder, sprintf('sub_%d_Structured_Pipeline_Table.xlsx', sub_no));
pipeline_table_csv = fullfile(pipeline_folder, sprintf('sub_%d_Structured_Pipeline_Table.csv', sub_no));
writetable(pipeline_table, pipeline_table_xlsx);
writetable(pipeline_table, pipeline_table_csv);

pipeline_diagram_png = fullfile(pipeline_folder, sprintf('sub_%d_Pipeline_Flow_Diagram.png', sub_no));
fig_pipe = figure('Visible','off', 'Color','w', 'Position',[100 100 1500 900]);
axis off
pipeline_lines = {
    'STRUCTURED EEG-ONLY PIPELINE FLOW'
    ' '
    'EDF file'
    '  ↓'
    'EDF read: data + info + labels'
    '  ↓'
    'Auto channel detection: EEG channels + ECG/EKG channels'
    '  ↓'
    'Universal sampling: resample every selected channel to Fs'
    '  ↓'
    'EEG preprocessing: mean removal → 50 Hz notch → 0.5-30 Hz bandpass'
    '  ↓'
    'EEG quality cleanup: remove flat/static/sine-like bad EEG channels'
    '  ↓'
    'EEG-only candidate creation: 2-5 Hz power + line-length morphology + multi-channel vote'
    '  ↓'
    'Candidate merge: close fragments joined before duration check'
    '  ↓'
    'EEG-only validation: frequency + power rise + spectral ratio + channel spread + morphology + artifact score'
    '  ↓'
    'Kept events: RED = very possible, YELLOW = suspicious review, GREEN = weak review'
    '  ↓'
    'ECG post-detection only: same time window → HR, SDNN, RMSSD'
    '  ↓'
    'Outputs: Excel/CSV + all-channel screenshots + graph-only PDF + marked viewer'
};
text(0.05, 0.96, pipeline_lines, ...
    'Units','normalized', ...
    'VerticalAlignment','top', ...
    'FontSize',15, ...
    'FontName','Consolas', ...
    'Color','k', ...
    'Interpreter','none');
exportgraphics(fig_pipe, pipeline_diagram_png, 'Resolution', 220, 'BackgroundColor', 'white');
close(fig_pipe);

fprintf('Saved text report: %s\n', report_file);
fprintf('Saved pipeline explanation: %s\n', pipeline_file);
fprintf('Saved structured pipeline table: %s\n', pipeline_table_xlsx);
fprintf('Saved pipeline flow diagram: %s\n', pipeline_diagram_png);

%% ============================================================
% BLOCK 12: SAVE FULL DETECTION PLOT
% Full plot contains ALL EEG channels + selected best ECG/EKG.
% ECG is not averaged.
% ECG is cleaned only inside EEG-detected event windows.
%% ============================================================

fig_full = figure('Name', sprintf('sub_%d Full All-Channel Detection', sub_no), ...
    'Visible', 'off', ...
    'Color', 'w', ...
    'Position', [100 100 1500 900]);

ax_eeg = subplot(5,1,1:4);
plotStackedEEGAxes(ax_eeg, t, eeg_matrix, labels(eeg_channels), seizure_starts, seizure_ends, event_color_status, ...
    sprintf('sub_%d Full Multi-Channel EEG | RED/YELLOW/GREEN EEG-only windows', sub_no), true);

ax_ecg = subplot(5,1,5);

plot(t, ecg_display_clean, 'k', 'LineWidth', 0.8);
hold on
markEventWindows(ax_ecg, seizure_starts, seizure_ends, event_color_status);

if has_ecg
    ecg_plot_title = sprintf('Selected best ECG/EKG: %s | cleaned only inside EEG event windows', string(labels(ecg_channel)));
else
    ecg_plot_title = 'No ECG/EKG found';
end

title(ecg_plot_title, 'Color', 'k', 'Interpreter', 'none');
xlabel('Time (sec)', 'Color', 'k');
ylabel('ECG', 'Color', 'k');
grid on
setWhiteAxes(ax_ecg);

full_plot_png = fullfile(plots_folder, sprintf('sub_%d_Full_All_Channel_EEG_BEST_ECG.png', sub_no));
full_plot_fig = fullfile(plots_folder, sprintf('sub_%d_Full_All_Channel_EEG_BEST_ECG.fig', sub_no));

saveFigurePNG(fig_full, full_plot_png);
savefig(fig_full, full_plot_fig);
close(fig_full);

fprintf('Saved full all-channel detection plot with selected best ECG/EKG.\n');

%% ============================================================
% BLOCK 13: SAVE EVENT SCREENSHOTS
% Each event image has max 3 parts:
% 1. Big multi-channel EEG panel
% 2. Selected best ECG/EKG same time window
% 3. HR/SDNN/RMSSD summary
%% ============================================================

for s = 1:length(seizure_starts)

    event_folder = fullfile(screenshots_folder, sprintf('Event_%d', s));
    createFolder(event_folder);

    plot_start = max(0, seizure_starts(s) - screenshot_padding_sec);
    plot_end = min(total_duration, seizure_ends(s) + screenshot_padding_sec);
    idx_plot = t >= plot_start & t <= plot_end;

    fig_event = figure( ...
        'Name', sprintf('sub_%d Event_%d EEG-only Window', sub_no, s), ...
        'Visible', 'off', ...
        'Color', 'w', ...
        'Position', [80 40 1500 1000]);

    sgtitle(sprintf('sub_%d | Event %d | %s | %s | %.2f-%.2f sec | EEG-only detection', ...
        sub_no, s, char(event_status(s)), char(event_color_status(s)), seizure_starts(s), seizure_ends(s)), ...
        'Color', 'k', 'FontWeight', 'bold', 'Interpreter', 'none');

    ax1 = axes('Parent', fig_event, 'Position', [0.07 0.37 0.90 0.53]);
    plotStackedEEGAxes(ax1, t(idx_plot), eeg_matrix(idx_plot,:), labels(eeg_channels), ...
        seizure_starts(s), seizure_ends(s), event_color_status(s), ...
        'Clear multi-channel EEG event view: 10 sec before + event + 10 sec after', false);

    ax2 = axes('Parent', fig_event, 'Position', [0.07 0.22 0.90 0.10]);

    plot(ax2, t(idx_plot), ecg_display_clean(idx_plot), 'k', 'LineWidth', 0.9);
    hold(ax2, 'on');
    markEventWindows(ax2, seizure_starts(s), seizure_ends(s), event_color_status(s));

    if has_ecg
        ecg_event_title = sprintf('Selected best ECG/EKG only: %s | EEG-leakage reduced inside event window', string(labels(ecg_channel)));
    else
        ecg_event_title = 'No ECG/EKG available';
    end

    title(ax2, ecg_event_title, 'Color', 'k', 'Interpreter', 'none');
    xlabel(ax2, 'Time (sec)', 'Color', 'k');
    ylabel(ax2, 'ECG', 'Color', 'k');
    grid(ax2, 'on');
    setWhiteAxes(ax2);

    ax3 = axes('Parent', fig_event, 'Position', [0.07 0.06 0.90 0.10]);

    if has_ecg && height(patient_result) >= s && patient_result.Event(s) ~= 0
        hrv_values = [patient_result.HR_Before_bpm(s), patient_result.HR_During_bpm(s), patient_result.HR_After_bpm(s); ...
                      patient_result.SDNN_Before_ms(s), patient_result.SDNN_During_ms(s), patient_result.SDNN_After_ms(s); ...
                      patient_result.RMSSD_Before_ms(s), patient_result.RMSSD_During_ms(s), patient_result.RMSSD_After_ms(s)];
        bar(ax3, hrv_values');
        set(ax3, 'XTickLabel', {'Before', 'During', 'After'});
        legend(ax3, {'HR bpm', 'SDNN ms', 'RMSSD ms'}, 'Location', 'bestoutside');
        title(ax3, sprintf('ECG/HRV summary after EEG detection | %s', string(patient_result.HRV_Label(s))), 'Color', 'k');
        ylabel(ax3, 'Value', 'Color', 'k');
    else
        text(ax3, 0.5, 0.5, 'No ECG / HRV data available', 'HorizontalAlignment', 'center');
        xlim(ax3, [0 1]);
        ylim(ax3, [0 1]);
        title(ax3, 'ECG/HRV Summary', 'Color', 'k');
    end

    grid(ax3, 'on');
    setWhiteAxes(ax3);

    full_event_png = fullfile(event_folder, ...
        sprintf('sub_%d_Event_%d_ALL_CHANNEL_EEG_BEST_ECG_%.2f_to_%.2f_sec.png', ...
        sub_no, s, plot_start, plot_end));

    full_event_fig = fullfile(event_folder, ...
        sprintf('sub_%d_Event_%d_ALL_CHANNEL_EEG_BEST_ECG_%.2f_to_%.2f_sec.fig', ...
        sub_no, s, plot_start, plot_end));

    saveFigurePNG(fig_event, full_event_png);
    savefig(fig_event, full_event_fig);
    close(fig_event);
end

fprintf('Saved all-channel event screenshots with selected best ECG/EKG.\n');
%% ============================================================
% BLOCK 14: CHECKING / VERIFICATION PIPELINE
%% ============================================================

check_subject = sub_no;
check_edf_file_exists = isfile(filename);
check_subject_folder_created = isfolder(subject_folder);
check_tables_folder_created = isfolder(tables_folder);
check_plots_folder_created = isfolder(plots_folder);
check_screenshots_folder_created = isfolder(screenshots_folder);
check_report_file_created = isfile(report_file);
check_excel_file_created = isfile(subject_excel_file);
check_csv_file_created = isfile(subject_csv_file);
check_combined_csv_created = isfile(combined_csv_file);
check_combined_excel_created = isfile(combined_excel_file);
check_full_plot_created = isfile(full_plot_png);
check_total_detected_events = height(final_events);
check_total_review_events = height(review_events);
check_total_report_windows = length(seizure_starts);
check_red_event_count = sum(string(event_color_status) == "RED");
check_yellow_event_count = sum(string(event_color_status) == "YELLOW");
check_green_event_count = sum(string(event_color_status) == "GREEN");
check_has_ecg = has_ecg;
check_eeg_channel_count = length(eeg_channels);
check_removed_eeg_channel_count = length(removed_eeg_channels);
check_fs = Fs;
check_total_duration_sec = total_duration;

png_files = dir(fullfile(screenshots_folder, '**', '*.png'));
check_total_event_screenshots = length(png_files);

if length(eeg_channels) >= 8
    check_eeg_channel_check = "PASS";
else
    check_eeg_channel_check = "LOW CHANNEL COUNT";
end

if Fs > 0 && total_duration > 60
    check_signal_length_check = "PASS";
else
    check_signal_length_check = "CHECK SIGNAL LENGTH";
end

if isfile(subject_excel_file) && isfile(report_file) && isfile(full_plot_png)
    check_output_save_check = "PASS";
else
    check_output_save_check = "FAIL";
end

if check_total_report_windows == 0
    check_event_check = "NO EEG EVENT DETECTED";
else
    check_event_check = "EEG EVENTS / REVIEW WINDOWS DETECTED";
end

check_best_confidence_score = NaN;
check_best_confidence_grade = "NO EVENT";

if istable(patient_result) && ~isempty(patient_result) && any(strcmp(patient_result.Properties.VariableNames, 'Confidence_Score'))
    conf_scores = double(patient_result.Confidence_Score);
    valid_conf_idx = isfinite(conf_scores);

    if any(valid_conf_idx)
        valid_scores = conf_scores;
        valid_scores(~valid_conf_idx) = -inf;
        [check_best_confidence_score, best_idx] = max(valid_scores);
        check_best_confidence_grade = string(patient_result.Confidence_Grade(best_idx));
    end
end

check_result = table( ...
    check_subject, check_edf_file_exists, check_subject_folder_created, ...
    check_tables_folder_created, check_plots_folder_created, check_screenshots_folder_created, ...
    check_report_file_created, check_excel_file_created, check_csv_file_created, ...
    check_combined_csv_created, check_combined_excel_created, check_full_plot_created, ...
    check_total_detected_events, check_total_review_events, check_total_report_windows, ...
    check_red_event_count, check_yellow_event_count, check_green_event_count, ...
    check_has_ecg, check_eeg_channel_count, check_removed_eeg_channel_count, check_fs, ...
    check_total_duration_sec, check_total_event_screenshots, check_eeg_channel_check, ...
    check_signal_length_check, check_output_save_check, check_event_check, ...
    check_best_confidence_score, check_best_confidence_grade, ...
    'VariableNames', { ...
        'Subject', 'EDF_File_Exists', 'Subject_Folder_Created', ...
        'Tables_Folder_Created', 'Plots_Folder_Created', 'Screenshots_Folder_Created', ...
        'Report_File_Created', 'Excel_File_Created', 'CSV_File_Created', ...
        'Combined_CSV_Created', 'Combined_Excel_Created', 'Full_Plot_Created', ...
        'Final_Likely_EEG_Events', 'Review_EEG_Events', 'Total_Report_Windows', ...
        'RED_Very_Possible_Windows', 'YELLOW_Suspicious_Windows', 'GREEN_Weak_Windows', ...
        'Has_ECG', 'EEG_Channel_Count', 'Removed_EEG_Channel_Count', 'Fs', ...
        'Total_Duration_sec', 'Total_Event_Screenshots', 'EEG_Channel_Check', ...
        'Signal_Length_Check', 'Output_Save_Check', 'Event_Check', ...
        'Best_Confidence_Score', 'Best_Confidence_Grade'});

check_excel_file = fullfile(check_folder, sprintf('sub_%d_Checking_Pipeline.xlsx', sub_no));
check_csv_file = fullfile(check_folder, sprintf('sub_%d_Checking_Pipeline.csv', sub_no));

writetable(check_result, check_excel_file);
writetable(check_result, check_csv_file);

disp(check_result);

fprintf('\nSaved checking pipeline Excel: %s\n', check_excel_file);
fprintf('Saved checking pipeline CSV: %s\n', check_csv_file);

%% ============================================================
% BLOCK 15: CREATE FINAL COMBINED PDF REPORT
% PDF contains graph-type outputs only. No table pages.
%% ============================================================

pdf_report_file = fullfile(reports_folder, sprintf('sub_%d_Final_Combined_Report.pdf', sub_no));

if isfile(pdf_report_file)
    try
        delete(pdf_report_file);
    catch
        error('Could not delete old PDF. Close it if open, then run again: %s', pdf_report_file);
    end
end

%% ---------------- PAGE 1: TITLE + PIPELINE SUMMARY ----------------
fig_pdf1 = figure('Visible','off', 'Color','w', 'Position',[100 100 1000 760]);
axis off

if has_ecg
    ecg_status_text = "YES";
    ecg_channel_text = string(labels(ecg_channel));
else
    ecg_status_text = "NO";
    ecg_channel_text = "Not found";
end

summary_text = {
    'EEG-ONLY MULTI-CHANNEL ABSENCE-SEIZURE-LIKE ANALYSIS REPORT'
    ' '
    sprintf('Subject: sub_%d', sub_no)
    sprintf('EDF File: %s', filename)
    sprintf('Total Duration: %.2f sec / %.2f min', total_duration, total_duration/60)
    sprintf('Sampling Rate Used: %.2f Hz', Fs)
    sprintf('EEG Channels Used After Cleanup: %d', length(eeg_channels))
    sprintf('Removed EEG Channels: %d', length(removed_eeg_channels))
    sprintf('EEG Reference / Montage Mode: %s', montage_note)
    sprintf('ECG Available: %s', ecg_status_text)
    sprintf('Selected ECG/EKG Channel: %s', ecg_channel_text)
    sprintf('Final Likely EEG Events: %d', height(final_events))
    sprintf('Review EEG Windows: %d', height(review_events))
    sprintf('RED very possible windows: %d', red_event_count)
    sprintf('YELLOW suspicious review windows: %d', yellow_event_count)
    sprintf('GREEN weak review windows: %d', green_event_count)
    ' '
    'COLOR LEGEND:'
    'RED = very possible / likely EEG event'
    'YELLOW = suspicious review-needed EEG event'
    'GREEN = weak / low-confidence review window'
    ' '
    'MAIN RULE:'
    'Seizure-like windows are detected using EEG only.'
    'ECG is shown only after EEG detection for HR / HRV / visual checking.'
    ' '
    'Detection logic:'
    '1. EDF loading and automatic channel detection'
    '2. EEG resampling, 50 Hz notch, 0.5-30 Hz bandpass'
    '3. Bad/static EEG channel removal'
    '4. EEG-only 2-5 Hz power + multi-channel vote'
    '5. Close fragment merge, then 5-30 sec FINAL and 30-180 sec prolonged REVIEW check'
    '6. 30 sec context validation using frequency, spread, power rise, and morphology'
    '7. ECG HR / SDNN / RMSSD calculated only after EEG windows are found'
    '8. Graph-only PDF export with all-channel EEG screenshots'
    ' '
    'PDF CONTENT RULE:'
    'This PDF contains only graph-type outputs. Tables are saved separately as Excel/CSV.'
    ' '
    'NOTE: Signal-analysis classification only, not clinical diagnosis.'
};

text(0.05, 0.95, summary_text, ...
    'Units','normalized', ...
    'VerticalAlignment','top', ...
    'FontSize',11, ...
    'FontName','Consolas', ...
    'Color','k', ...
    'Interpreter','none');

exportgraphics(fig_pdf1, pdf_report_file, ...
    'ContentType','vector', ...
    'BackgroundColor','white');

close(fig_pdf1);

%% ---------------- PAGE 2: STRUCTURED PIPELINE FLOW DIAGRAM ----------------
if exist('pipeline_diagram_png', 'var') && isfile(pipeline_diagram_png)
    img_pipe = imread(pipeline_diagram_png);

    fig_pdf_pipe = figure('Visible','off', 'Color','w', 'Position',[100 100 1300 850]);
    imshow(img_pipe);
    title('STRUCTURED PIPELINE FLOW: output of each step becomes input to next step', ...
        'FontSize',15, 'FontWeight','bold', 'Color','k', 'Interpreter','none');

    exportgraphics(fig_pdf_pipe, pdf_report_file, ...
        'ContentType','image', ...
        'BackgroundColor','white', ...
        'Append',true);

    close(fig_pdf_pipe);
end

%% ---------------- PAGE 3: FULL ALL-CHANNEL EEG / ECG PLOT ----------------
if isfile(full_plot_png)
    img_full = imread(full_plot_png);

    fig_pdf_full = figure('Visible','off', 'Color','w', 'Position',[100 100 1300 850]);
    imshow(img_full);
    title('FULL ALL-CHANNEL EEG + BEST SINGLE ECG/EKG PLOT', 'FontSize',16, 'FontWeight','bold', 'Color','k');

    exportgraphics(fig_pdf_full, pdf_report_file, ...
        'ContentType','image', ...
        'BackgroundColor','white', ...
        'Append',true);

    close(fig_pdf_full);
else
    warning('Full detection plot PNG not found. Skipping full plot page.');
end

%% ---------------- EVENT GRAPH PAGES ONLY ----------------
for s = 1:length(seizure_starts)

    event_folder = fullfile(screenshots_folder, sprintf('Event_%d', s));
    event_png_files = dir(fullfile(event_folder, '*ALL_CHANNEL_EEG_BEST_ECG*.png'));

    if isempty(event_png_files)
        event_png_files = dir(fullfile(event_folder, '*ALL_CHANNEL_EEG_ECG*.png'));
    end

    if isempty(event_png_files)
        warning('No all-channel event PNG found for Event %d. Skipping PDF page.', s);
        continue;
    end

    event_png_path = fullfile(event_folder, event_png_files(1).name);
    img_event = imread(event_png_path);

    fig_event_pdf = figure('Visible','off', 'Color','w', 'Position',[100 100 1300 850]);
    imshow(img_event);
    title(sprintf('SUBJECT %d - EVENT %d | %s | %s | %.2f sec to %.2f sec', ...
        sub_no, s, char(event_status(s)), char(event_color_status(s)), seizure_starts(s), seizure_ends(s)), ...
        'FontSize',14, 'FontWeight','bold', 'Color','k', 'Interpreter','none');

    exportgraphics(fig_event_pdf, pdf_report_file, ...
        'ContentType','image', ...
        'BackgroundColor','white', ...
        'Append',true);

    close(fig_event_pdf);
end

fprintf('Saved graph-only final PDF report: %s\n', pdf_report_file);

%% ============================================================
% FINAL CMD SUMMARY
%% ============================================================

fprintf('\n\n================ FINAL SUMMARY ================\n');
fprintf('Subject: sub_%d\n', sub_no);
fprintf('Final likely EEG events: %d\n', height(final_events));
fprintf('Review EEG windows: %d\n', height(review_events));
fprintf('Output folder: %s\n', subject_folder);
fprintf('Excel summary: %s\n', subject_excel_file);
fprintf('Text report: %s\n', report_file);
fprintf('Pipeline flow: %s\n', pipeline_file);
fprintf('Checking file: %s\n', check_excel_file);

if exist('pdf_report_file', 'var') && isfile(pdf_report_file)
    fprintf('Final PDF report: %s\n', pdf_report_file);
else
    fprintf('Final PDF report: Not created / check BLOCK 15\n');
end

fprintf('\nNOTE: EEG decides seizure-like classification. ECG is post-detection only.\n');
fprintf('NOTE: Signal-analysis classification only, not clinical diagnosis.\n');

%% ============================================================
% BLOCK 16: INTERACTIVE STACKED EEG + BEST SINGLE ECG REVIEW VIEWER
% Final/review EEG windows are marked in the viewer.
%
% ECG rule:
% - Uses only selected best ECG/EKG channel.
% - No ECG averaging.
% - No ECG overlap.
% - Uses ecg_display_clean, where only EEG-detected event windows
%   were cleaned after detection.
%% ============================================================

interactive_start_sec = 100;
interactive_window_sec = 10;
interactive_step_sec = 5;
interactive_xtick_gap_sec = 1;

if has_ecg
    viewer_ecg_label = string(labels(ecg_channel));
else
    viewer_ecg_label = "NO ECG/EKG";
end

openReviewStackedViewer( ...
    t, ...
    eeg_matrix, ...
    ecg_display_clean, ...
    labels, ...
    eeg_channels, ...
    total_duration, ...
    sub_no, ...
    interactive_start_sec, ...
    interactive_window_sec, ...
    interactive_step_sec, ...
    interactive_xtick_gap_sec, ...
    seizure_starts, ...
    seizure_ends, ...
    event_color_status, ...
    viewer_ecg_label);

fprintf('\nInteractive stacked review viewer opened with marked EEG-only windows.\n');
fprintf('Viewer ECG rule: selected best ECG/EKG only, no averaging, cleaned only inside EEG event windows.\n');
fprintf('Use buttons, keyboard arrows, mouse pan/zoom, jump box, and save image.\n');


%% ============================================================
% LOCAL FUNCTIONS
%% ============================================================

function sig = getSignal(data, ch)
    sig = data{:, ch};

    if iscell(sig)
        sig = cell2mat(sig);
    end

    if istimetable(sig)
        sig = sig{:, :};
    end

    sig = double(sig(:));
end

function total_duration = getTotalDurationSec(info)
    dur = info.DataRecordDuration;

    if isduration(dur)
        dur_sec = seconds(dur);
    else
        dur_sec = double(dur);
    end

    total_duration = double(info.NumDataRecords) * dur_sec;
end

function [mean_HR, SDNN, RMSSD, RPeak_Count] = get_hrv(ecg_segment, Fs)
    ecg_segment = double(ecg_segment(:));

    if length(ecg_segment) < Fs * 3 || all(isnan(ecg_segment))
        mean_HR = NaN;
        SDNN = NaN;
        RMSSD = NaN;
        RPeak_Count = 0;
        return;
    end

    ecg_segment = fillmissing(ecg_segment, 'linear', 'EndValues', 'nearest');
    ecg_segment = ecg_segment - mean(ecg_segment, 'omitnan');

    min_peak_distance = round(0.4 * Fs);

    peak_threshold_pos = mean(ecg_segment, 'omitnan') + 1.5 * std(ecg_segment, 'omitnan');

    try
        [~, locs_pos] = findpeaks(ecg_segment, ...
            'MinPeakDistance', min_peak_distance, ...
            'MinPeakHeight', peak_threshold_pos);
    catch
        locs_pos = [];
    end

    ecg_inv = -ecg_segment;
    peak_threshold_neg = mean(ecg_inv, 'omitnan') + 1.5 * std(ecg_inv, 'omitnan');

    try
        [~, locs_neg] = findpeaks(ecg_inv, ...
            'MinPeakDistance', min_peak_distance, ...
            'MinPeakHeight', peak_threshold_neg);
    catch
        locs_neg = [];
    end

    if length(locs_neg) > length(locs_pos)
        locs = locs_neg;
    else
        locs = locs_pos;
    end

    RPeak_Count = length(locs);

    if length(locs) < 3
        mean_HR = NaN;
        SDNN = NaN;
        RMSSD = NaN;
        return;
    end

    RR_sec = diff(locs) / Fs;
    RR_sec = RR_sec(RR_sec >= 0.35 & RR_sec <= 1.8);

    if length(RR_sec) < 2
        mean_HR = NaN;
        SDNN = NaN;
        RMSSD = NaN;
        return;
    end

    RR_ms = RR_sec * 1000;
    mean_HR = 60 / mean(RR_sec, 'omitnan');
    SDNN = std(RR_ms, 'omitnan');
    RMSSD = sqrt(mean(diff(RR_ms).^2, 'omitnan'));
end

function createFolder(folder_path)
    if ~isfolder(folder_path)
        mkdir(folder_path);
    end
end

function grade = getConfidenceGrade(score, high_cutoff, medium_cutoff)
    if isnan(score)
        grade = "NO SCORE";
    elseif score >= high_cutoff
        grade = "HIGH";
    elseif score >= medium_cutoff
        grade = "MEDIUM";
    else
        grade = "LOW";
    end
end

function setWhiteAxes(ax)
    ax.Color = 'w';
    ax.XColor = 'k';
    ax.YColor = 'k';
    ax.GridColor = [0.6 0.6 0.6];
    ax.Box = 'on';
end

function saveFigurePNG(fig_handle, png_file)
    try
        exportgraphics(fig_handle, png_file, ...
            'Resolution', 220, ...
            'BackgroundColor', 'white');
    catch
        saveas(fig_handle, png_file);
    end
end

function y = applyNotch50Hz(x, Fs)
    x = double(x(:));

    if Fs <= 110
        y = x;
        return;
    end

    notch_low = 49;
    notch_high = 51;

    if notch_high >= Fs/2
        y = x;
        return;
    end

    [b, a] = butter(2, [notch_low notch_high] / (Fs/2), 'stop');
    y = filtfilt(b, a, x);
end

function p = robustPercentile(x, pct)
    x = double(x(:));
    x = x(isfinite(x));

    if isempty(x)
        p = NaN;
        return;
    end

    x = sort(x);
    pct = max(0, min(100, pct));

    idx = 1 + (length(x)-1) * pct / 100;
    lo = floor(idx);
    hi = ceil(idx);

    if lo == hi
        p = x(lo);
    else
        p = x(lo) + (idx - lo) * (x(hi) - x(lo));
    end
end

function [good_mask, quality_table] = getEEGChannelQuality(eeg_matrix, Fs, eeg_names)
    n_ch = size(eeg_matrix, 2);

    Channel = strings(n_ch,1);
    StdValue = nan(n_ch,1);
    RobustRange = nan(n_ch,1);
    NaNFraction = nan(n_ch,1);
    RepeatedValueFraction = nan(n_ch,1);
    SingleFrequencyDominance = nan(n_ch,1);
    Keep = true(n_ch,1);
    Reason = strings(n_ch,1);

    for ch = 1:n_ch
        Channel(ch) = string(eeg_names(ch));

        x = double(eeg_matrix(:,ch));
        NaNFraction(ch) = mean(isnan(x));

        x = fillmissing(x, 'linear', 'EndValues', 'nearest');
        x = x - median(x, 'omitnan');

        StdValue(ch) = std(x, 'omitnan');
        RobustRange(ch) = robustPercentile(x, 95) - robustPercentile(x, 5);

        dx = abs(diff(x));

        if isempty(dx)
            RepeatedValueFraction(ch) = 1;
        else
            RepeatedValueFraction(ch) = mean(dx < 1e-10);
        end

        try
            win_len = min(length(x), round(4 * Fs));

            if win_len < 16
                SingleFrequencyDominance(ch) = 1;
            else
                nfft = max(512, 2^nextpow2(win_len));
                [pxx, f] = pwelch(x, hamming(win_len), floor(win_len/2), nfft, Fs);

                band = f >= 0.5 & f <= 30;
                pband = pxx(band);

                if isempty(pband) || sum(pband) <= 0
                    SingleFrequencyDominance(ch) = 1;
                else
                    SingleFrequencyDominance(ch) = max(pband) / sum(pband);
                end
            end
        catch
            SingleFrequencyDominance(ch) = NaN;
        end

        reasons = strings(0,1);

        if NaNFraction(ch) > 0.20
            reasons(end+1,1) = "too many NaN samples";
        end

        if StdValue(ch) < 1e-8 || RobustRange(ch) < 1e-8
            reasons(end+1,1) = "flat/nearly flat";
        end

        if RepeatedValueFraction(ch) > 0.95
            reasons(end+1,1) = "mostly repeated/static samples";
        end

        if isfinite(SingleFrequencyDominance(ch)) && SingleFrequencyDominance(ch) > 0.85
            reasons(end+1,1) = "single-frequency/static sine-like channel";
        end

        if isempty(reasons)
            Keep(ch) = true;
            Reason(ch) = "usable";
        else
            Keep(ch) = false;
            Reason(ch) = strjoin(reasons, " | ");
        end
    end

    good_mask = Keep;

    quality_table = table(Channel, StdValue, RobustRange, NaNFraction, ...
        RepeatedValueFraction, SingleFrequencyDominance, Keep, Reason);
end

function plotStackedEEGAxes(ax, t, eeg_matrix, eeg_names, event_starts, event_ends, event_status, plot_title, allow_downsample)
    axes(ax);
    cla(ax);
    hold(ax, 'on');

    t = double(t(:));
    eeg_matrix = double(eeg_matrix);

    if nargin < 9
        allow_downsample = true;
    end

    n_samples = min(length(t), size(eeg_matrix,1));
    t = t(1:n_samples);
    eeg_matrix = eeg_matrix(1:n_samples,:);

    max_plot_points = 6000;

    if allow_downsample && length(t) > max_plot_points
        pick = round(linspace(1, length(t), max_plot_points));
        t_plot = t(pick);
        eeg_plot = eeg_matrix(pick,:);
    else
        t_plot = t;
        eeg_plot = eeg_matrix;
    end

    n_ch = size(eeg_plot, 2);
    vertical_gap = 5;
    offsets = ((n_ch:-1:1) * vertical_gap);

    y_min = -vertical_gap;
    y_max = max(offsets) + vertical_gap;

    ylim(ax, [y_min y_max]);

    markEventWindows(ax, event_starts, event_ends, event_status);

    for ch = 1:n_ch
        y = eeg_plot(:,ch);
        y = fillmissing(y, 'linear', 'EndValues', 'nearest');
        y = y - median(y, 'omitnan');

        scale_val = std(y, 'omitnan');

        if isnan(scale_val) || scale_val == 0
            scale_val = 1;
        end

        y = y ./ scale_val;
        y = y + offsets(ch);

        plot(ax, t_plot, y, 'LineWidth', 0.7);
    end

    if n_ch <= 40
        yticks(ax, fliplr(offsets));
        yticklabels(ax, flipud(string(eeg_names(:))));
    end

    title(ax, plot_title, 'Color', 'k', 'Interpreter', 'none');
    xlabel(ax, 'Time (sec)', 'Color', 'k');
    ylabel(ax, 'EEG channels', 'Color', 'k');

    grid(ax, 'on');
    setWhiteAxes(ax);

    if ~isempty(t_plot)
        xlim(ax, [min(t_plot), max(t_plot)]);
    end
end

function markEventWindows(ax, event_starts, event_ends, event_status)
    if isempty(event_starts)
        return;
    end

    yl = ylim(ax);

    for k = 1:length(event_starts)
        s = event_starts(k);
        e = event_ends(k);

        if k <= length(event_status)
            status = string(event_status(k));
        else
            status = "EVENT";
        end

        [patch_color, line_color, face_alpha] = getEventMarkColors(status);

        patch(ax, [s e e s], [yl(1) yl(1) yl(2) yl(2)], patch_color, ...
            'FaceAlpha', face_alpha, ...
            'EdgeColor', 'none', ...
            'HandleVisibility', 'off');

        xline(ax, s, '-', ...
            'Color', line_color, ...
            'LineWidth', 1.2, ...
            'HandleVisibility', 'off');

        xline(ax, e, '-', ...
            'Color', line_color, ...
            'LineWidth', 1.2, ...
            'HandleVisibility', 'off');
    end
end

function [patch_color, line_color, face_alpha] = getEventMarkColors(status)
    status = upper(string(status));

    if status == "RED" || contains(status, "RED") || status == "FINAL"
        patch_color = [1.00 0.78 0.78];
        line_color = [0.85 0.00 0.00];
        face_alpha = 0.30;

    elseif status == "YELLOW" || contains(status, "YELLOW") || status == "REVIEW"
        patch_color = [1.00 0.95 0.55];
        line_color = [0.85 0.55 0.00];
        face_alpha = 0.28;

    elseif status == "GREEN" || contains(status, "GREEN")
        patch_color = [0.75 1.00 0.75];
        line_color = [0.00 0.55 0.00];
        face_alpha = 0.25;

    else
        patch_color = [0.88 0.88 0.88];
        line_color = [0.35 0.35 0.35];
        face_alpha = 0.18;
    end
end

function y = resampleAndMatchLength(x, Fs_from, Fs_to, target_len)
    x = double(x(:));

    if isempty(x)
        y = nan(target_len, 1);
        return;
    end

    if round(Fs_from) ~= round(Fs_to)
        [p, q] = rat(Fs_to / Fs_from);
        x = resample(x, p, q);
    end

    if length(x) > target_len
        x = x(1:target_len);
    elseif length(x) < target_len
        x(end+1:target_len) = x(end);
    end

    y = double(x(:));
end

function [best_score, best_hr, best_count, best_polarity, note] = getBestECGChannelScore(ecg_filt, Fs)
    ecg_filt = double(ecg_filt(:));
    ecg_filt = fillmissing(ecg_filt, 'linear', 'EndValues', 'nearest');
    ecg_filt = ecg_filt - median(ecg_filt, 'omitnan');

    [score_pos, hr_pos, count_pos, note_pos] = scoreECGPolarity(ecg_filt, Fs, "POSITIVE");
    [score_neg, hr_neg, count_neg, note_neg] = scoreECGPolarity(-ecg_filt, Fs, "NEGATIVE");

    if score_neg > score_pos
        best_score = score_neg;
        best_hr = hr_neg;
        best_count = count_neg;
        best_polarity = "NEGATIVE";
        note = note_neg;
    else
        best_score = score_pos;
        best_hr = hr_pos;
        best_count = count_pos;
        best_polarity = "POSITIVE";
        note = note_pos;
    end
end

function [score, est_hr, r_count, note] = scoreECGPolarity(y, Fs, polarity_name)
    y = double(y(:));
    y = fillmissing(y, 'linear', 'EndValues', 'nearest');
    y = y - median(y, 'omitnan');

    est_hr = NaN;
    r_count = 0;
    note = "weak / unusable ECG";

    if length(y) < round(10 * Fs) || std(y, 'omitnan') == 0
        score = 0;
        return;
    end

    noise_val = 1.4826 * mad(y, 1);

    if ~isfinite(noise_val) || noise_val <= 0
        noise_val = std(y, 'omitnan');
    end

    if ~isfinite(noise_val) || noise_val <= 0
        noise_val = eps;
    end

    min_peak_distance = round(0.35 * Fs);

    try
        [pks, locs, widths, prominences] = findpeaks(y, ...
            'MinPeakDistance', min_peak_distance, ...
            'MinPeakProminence', 1.5 * noise_val);
    catch
        peak_threshold = mean(y, 'omitnan') + 1.5 * std(y, 'omitnan');

        try
            [pks, locs] = findpeaks(y, ...
                'MinPeakDistance', min_peak_distance, ...
                'MinPeakHeight', peak_threshold);
        catch
            pks = [];
            locs = [];
        end

        widths = nan(size(pks));
        prominences = abs(pks);
    end

    r_count = length(locs);

    if r_count < 5
        score = 5;
        note = polarity_name + " polarity: too few R-like peaks";
        return;
    end

    rr_sec = diff(locs) / Fs;
    rr_sec = rr_sec(rr_sec >= 0.35 & rr_sec <= 1.8);

    if length(rr_sec) < 4
        score = 10;
        note = polarity_name + " polarity: RR intervals not reliable";
        return;
    end

    est_hr = 60 / mean(rr_sec, 'omitnan');
    rr_cv = std(rr_sec, 'omitnan') / mean(rr_sec, 'omitnan');

    if est_hr >= 35 && est_hr <= 180
        hr_score = 1;
    else
        hr_score = 0.25;
    end

    regularity_score = max(0, 1 - min(rr_cv / 0.35, 1));

    if isempty(prominences) || all(~isfinite(prominences))
        prom_score = 0.2;
    else
        prom_score = min(median(prominences, 'omitnan') / (6 * noise_val), 1);
    end

    if isempty(widths) || all(~isfinite(widths))
        width_score = 0.5;
    else
        width_sec = widths / Fs;
        width_score = mean(width_sec >= 0.025 & width_sec <= 0.18, 'omitnan');

        if ~isfinite(width_score)
            width_score = 0.5;
        end
    end

    dy = abs(diff(y));
    sharp_ratio = robustPercentile(dy, 99) / (median(dy, 'omitnan') + eps);
    sharp_score = min(sharp_ratio / 12, 1);

    duration_sec = length(y) / Fs;
    expected_min_peaks = max(5, floor(duration_sec * 0.45));
    count_score = min(r_count / expected_min_peaks, 1);

    sine_penalty = 0;

    try
        win_len = min(length(y), round(6 * Fs));
        nfft = max(512, 2^nextpow2(win_len));

        [pxx, f] = pwelch(y, hamming(win_len), floor(win_len/2), nfft, Fs);

        band = f >= 0.5 & f <= 20;

        if any(band) && sum(pxx(band)) > 0
            single_freq_dominance = max(pxx(band)) / sum(pxx(band));

            if single_freq_dominance > 0.70 && width_score < 0.45
                sine_penalty = 0.35;
            end
        end
    catch
        sine_penalty = 0;
    end

    score_0_1 = ...
        0.22 * hr_score + ...
        0.22 * regularity_score + ...
        0.20 * width_score + ...
        0.16 * prom_score + ...
        0.12 * sharp_score + ...
        0.08 * count_score;

    score_0_1 = max(0, score_0_1 - sine_penalty);
    score = 100 * score_0_1;

    note = sprintf('%s polarity: HR %.1f bpm, RR-CV %.2f, width score %.2f, sharp score %.2f', ...
        polarity_name, est_hr, rr_cv, width_score, sharp_score);
end

function [is_usable, reject_reason, adjusted_score, raw_range, repeated_fraction, sine_dominance, qrs_rate_per_min] = ...
    rejectUselessECGChannel(ecg_raw, ecg_filt, Fs, quality_score, est_hr, r_count)

    ecg_raw = double(ecg_raw(:));
    ecg_filt = double(ecg_filt(:));

    is_usable = true;
    reasons = strings(0,1);
    adjusted_score = quality_score;
    raw_range = NaN;
    repeated_fraction = NaN;
    sine_dominance = NaN;
    qrs_rate_per_min = NaN;

    if isempty(ecg_raw) || length(ecg_raw) < round(5 * Fs)
        is_usable = false;
        reject_reason = "too short / empty ECG channel";
        adjusted_score = 0;
        return;
    end

    nan_fraction = mean(~isfinite(ecg_raw));

    ecg_raw = fillmissing(ecg_raw, 'linear', 'EndValues', 'nearest');
    ecg_filt = fillmissing(ecg_filt, 'linear', 'EndValues', 'nearest');

    ecg_raw = ecg_raw - median(ecg_raw, 'omitnan');
    ecg_filt = ecg_filt - median(ecg_filt, 'omitnan');

    raw_std = std(ecg_raw, 'omitnan');
    filt_std = std(ecg_filt, 'omitnan');
    raw_range = robustPercentile(ecg_raw, 99) - robustPercentile(ecg_raw, 1);

    d_filt = abs(diff(ecg_filt));
    if isempty(d_filt) || median(d_filt, 'omitnan') <= 0
        qrs_sharp_ratio = 0;
    else
        qrs_sharp_ratio = robustPercentile(d_filt, 99) / (median(d_filt, 'omitnan') + eps);
    end

    dx = abs(diff(ecg_raw));
    if isempty(dx)
        repeated_fraction = 1;
    else
        tiny_step = max(1e-10, 1e-8 * max(abs(raw_range), eps));
        repeated_fraction = mean(dx < tiny_step);
    end

    duration_min = length(ecg_raw) / Fs / 60;
    if duration_min > 0
        qrs_rate_per_min = r_count / duration_min;
    end

    if nan_fraction > 0.20
        reasons(end+1,1) = "too many NaN/non-finite samples";
    end

    if ~isfinite(raw_std) || raw_std <= 0 || ~isfinite(raw_range) || raw_range < 1e-8
        reasons(end+1,1) = "flat / nearly flat ECG channel";
    end

    if isfinite(repeated_fraction) && repeated_fraction > 0.98
        reasons(end+1,1) = "mostly repeated/static samples";
    end

    if ~isfinite(filt_std) || filt_std <= 0
        reasons(end+1,1) = "filtered ECG has no usable variation";
    end

    try
        win_len = min(length(ecg_raw), round(8 * Fs));

        if win_len >= 32
            nfft = max(1024, 2^nextpow2(win_len));
            [pxx, f] = pwelch(ecg_raw, hamming(win_len), floor(win_len/2), nfft, Fs);

            ecg_band = f >= 0.3 & f <= min(20, Fs/2 - 0.1);

            if any(ecg_band) && sum(pxx(ecg_band)) > 0
                sine_dominance = max(pxx(ecg_band)) / sum(pxx(ecg_band));
            end
        end
    catch
        sine_dominance = NaN;
    end

    % Reject the useless ECG/EKG labels you described: mostly one smooth
    % repeating sinusoid/static trace, with no believable QRS sequence.
    sine_like_bad = isfinite(sine_dominance) && sine_dominance >= 0.72 && ...
                    (quality_score < 65 || qrs_sharp_ratio < 6 || r_count < 8 || ~isfinite(est_hr));

    if sine_like_bad
        reasons(end+1,1) = "smooth single-frequency sine-like ECG, not believable QRS";
    end

    % Do not keep a channel just because it is labeled ECG/EKG. It needs at
    % least some realistic R-like peaks. Threshold is deliberately gentle so
    % noisy but important ECG is not thrown away too aggressively.
    too_few_peaks = r_count < 5 || ...
                    (isfinite(qrs_rate_per_min) && qrs_rate_per_min < 25 && quality_score < 60);

    if too_few_peaks
        reasons(end+1,1) = "too few believable R/QRS-like peaks";
    end

    if qrs_sharp_ratio < 3 && quality_score < 55
        reasons(end+1,1) = "not enough sharp QRS-like morphology";
    end

    if isfinite(est_hr) && (est_hr < 30 || est_hr > 200) && quality_score < 65
        reasons(end+1,1) = "estimated HR outside believable ECG range";
    end

    if ~isfinite(quality_score) || quality_score < 25
        reasons(end+1,1) = "very low ECG quality score";
    end

    if isempty(reasons)
        is_usable = true;
        reject_reason = "kept: usable ECG candidate";
    else
        is_usable = false;
        reject_reason = strjoin(unique(reasons, 'stable'), " | ");
    end

    if is_usable
        sine_penalty = 0;
        if isfinite(sine_dominance)
            sine_penalty = 15 * max(0, (sine_dominance - 0.45) / 0.35);
        end

        adjusted_score = quality_score - sine_penalty;
        adjusted_score = max(0, adjusted_score);
    else
        adjusted_score = 0;
    end
end


function [clean_display_seg, clean_filt_seg, corr_before, corr_after, hrv_clean_ok, note] = ...
    cleanECGOnlyDuringEvent(ecg_display, ecg_filt, eeg_matrix, t, Fs, start_sec, end_sec)

    idx_event = t >= start_sec & t <= end_sec;

    ecg_display_seg = double(ecg_display(idx_event));
    ecg_filt_seg = double(ecg_filt(idx_event));
    eeg_event = double(eeg_matrix(idx_event, :));

    clean_display_seg = ecg_display_seg;
    clean_filt_seg = ecg_filt_seg;

    corr_before = NaN;
    corr_after = NaN;
    hrv_clean_ok = false;
    note = "cleaning skipped";

    if length(ecg_display_seg) < round(2 * Fs) || size(eeg_event, 1) ~= length(ecg_display_seg)
        note = "event too short for ECG cleaning";
        return;
    end

    leakage_template_display = buildEEGLeakageTemplate(eeg_event, Fs, [2 5]);

    if all(~isfinite(leakage_template_display)) || std(leakage_template_display, 'omitnan') == 0
        note = "EEG leakage template unusable";
        return;
    end

    [candidate_display_clean, corr_before, corr_after, display_ok] = ...
        subtractTemplateFromSignal(ecg_display_seg, leakage_template_display);

    if display_ok
        clean_display_seg = candidate_display_clean;
    else
        clean_display_seg = ecg_display_seg;
    end

    leakage_template_hrv = buildEEGLeakageTemplate(eeg_event, Fs, [5 20]);

    [candidate_filt_clean, ~, ~, filt_math_ok] = ...
        subtractTemplateFromSignal(ecg_filt_seg, leakage_template_hrv);

    original_r_count = quickRPeakCount(ecg_filt_seg, Fs);
    cleaned_r_count = quickRPeakCount(candidate_filt_clean, Fs);

    original_std = std(ecg_filt_seg, 'omitnan');
    cleaned_std = std(candidate_filt_clean, 'omitnan');

    if filt_math_ok && ...
            cleaned_r_count >= max(3, round(0.60 * original_r_count)) && ...
            cleaned_std >= 0.35 * original_std && ...
            cleaned_std <= 2.50 * original_std

        clean_filt_seg = candidate_filt_clean;
        hrv_clean_ok = true;
        note = "display ECG cleaned; HRV ECG cleaned and accepted";

    else
        clean_filt_seg = ecg_filt_seg;
        hrv_clean_ok = false;
        note = "display ECG cleaned; HRV ECG kept original to avoid QRS damage";
    end
end

function template = buildEEGLeakageTemplate(eeg_event, Fs, freq_band)
    eeg_event = double(eeg_event);

    n_samples = size(eeg_event, 1);
    n_ch = size(eeg_event, 2);

    zmat = nan(n_samples, n_ch);

    for ch = 1:n_ch
        x = eeg_event(:, ch);
        x = fillmissing(x, 'linear', 'EndValues', 'nearest');
        x = x - median(x, 'omitnan');

        scale_val = 1.4826 * mad(x, 1);

        if ~isfinite(scale_val) || scale_val <= 0
            scale_val = std(x, 'omitnan');
        end

        if ~isfinite(scale_val) || scale_val <= 0
            continue;
        end

        x = x ./ scale_val;

        if Fs > 2 * freq_band(2) && freq_band(1) > 0
            try
                x = bandpass(x, freq_band, Fs);
            catch
                % Keep unfiltered template if bandpass fails.
            end
        end

        x = x - mean(x, 'omitnan');
        zmat(:, ch) = x;
    end

    template = median(zmat, 2, 'omitnan');
    template = fillmissing(template, 'linear', 'EndValues', 'nearest');
    template = template - mean(template, 'omitnan');

    temp_std = std(template, 'omitnan');

    if isfinite(temp_std) && temp_std > 0
        template = template ./ temp_std;
    end
end

function [clean_seg, corr_before, corr_after, ok] = subtractTemplateFromSignal(signal_seg, template)
    signal_seg = double(signal_seg(:));
    template = double(template(:));

    n = min(length(signal_seg), length(template));
    signal_seg = signal_seg(1:n);
    template = template(1:n);

    signal_seg = fillmissing(signal_seg, 'linear', 'EndValues', 'nearest');
    template = fillmissing(template, 'linear', 'EndValues', 'nearest');

    original_median = median(signal_seg, 'omitnan');

    y = signal_seg - original_median;
    r = template - mean(template, 'omitnan');

    if std(r, 'omitnan') <= 0 || std(y, 'omitnan') <= 0
        clean_seg = signal_seg;
        corr_before = NaN;
        corr_after = NaN;
        ok = false;
        return;
    end

    r = r ./ (std(r, 'omitnan') + eps);
    dr = [0; diff(r)];
    dr = dr ./ (std(dr, 'omitnan') + eps);

    X = [r dr];

    valid = all(isfinite(X), 2) & isfinite(y);

    if sum(valid) < max(20, round(0.5 * n))
        clean_seg = signal_seg;
        corr_before = NaN;
        corr_after = NaN;
        ok = false;
        return;
    end

    Xv = X(valid, :);
    yv = y(valid);

    lambda = 0.01 * trace(Xv' * Xv) / size(Xv, 2);
    beta = (Xv' * Xv + lambda * eye(size(Xv, 2))) \ (Xv' * yv);

    leakage_est = X * beta;
    clean_centered = y - leakage_est;
    clean_seg = clean_centered + original_median;

    corr_before = corr(y(valid), r(valid), 'Rows', 'complete');
    corr_after = corr(clean_centered(valid), r(valid), 'Rows', 'complete');

    std_original = std(signal_seg, 'omitnan');
    std_clean = std(clean_seg, 'omitnan');

    ok = isfinite(std_clean) && ...
         std_clean >= 0.20 * std_original && ...
         std_clean <= 3.00 * std_original;
end

function count = quickRPeakCount(ecg_segment, Fs)
    ecg_segment = double(ecg_segment(:));
    ecg_segment = fillmissing(ecg_segment, 'linear', 'EndValues', 'nearest');
    ecg_segment = ecg_segment - median(ecg_segment, 'omitnan');

    if length(ecg_segment) < round(2 * Fs) || std(ecg_segment, 'omitnan') == 0
        count = 0;
        return;
    end

    min_peak_distance = round(0.35 * Fs);

    pos_thr = mean(ecg_segment, 'omitnan') + 1.5 * std(ecg_segment, 'omitnan');
    neg_signal = -ecg_segment;
    neg_thr = mean(neg_signal, 'omitnan') + 1.5 * std(neg_signal, 'omitnan');

    try
        [~, locs_pos] = findpeaks(ecg_segment, ...
            'MinPeakDistance', min_peak_distance, ...
            'MinPeakHeight', pos_thr);

        [~, locs_neg] = findpeaks(neg_signal, ...
            'MinPeakDistance', min_peak_distance, ...
            'MinPeakHeight', neg_thr);

        count = max(length(locs_pos), length(locs_neg));
    catch
        count = 0;
    end
end

function openReviewStackedViewer(t, eeg_matrix, ecg_display, labels, eeg_channels, ...
    total_duration, sub_no, start_time, window_sec, step_sec, xtick_gap_sec, ...
    event_starts, event_ends, event_status, ecg_label)

    if nargin < 15 || isempty(ecg_label)
        ecg_label = "Selected best ECG/EKG";
    end

    t = t(:);

    if isduration(t)
        t = seconds(t);
    else
        t = double(t);
    end

    eeg_matrix = double(eeg_matrix);
    ecg_display = double(ecg_display(:));

    n_samples = min([length(t), size(eeg_matrix,1), length(ecg_display)]);

    t = t(1:n_samples);
    eeg_matrix = eeg_matrix(1:n_samples,:);
    ecg_display = ecg_display(1:n_samples);

    total_duration = min(total_duration, max(t));

    start_time = max(0, start_time);
    window_sec = max(1, window_sec);
    step_sec = max(1, step_sec);
    xtick_gap_sec = max(0.5, xtick_gap_sec);

    view_start = max(0, min(start_time, total_duration - window_sec));
    view_width = window_sec;

    min_view_width = 1;
    max_view_width = 180;
    max_display_points = 1000;

    eeg_count = size(eeg_matrix, 2);

    if isempty(eeg_channels)
        eeg_names = "EEG " + string(1:eeg_count);
    else
        eeg_names = strings(eeg_count,1);

        for k = 1:eeg_count
            if k <= length(eeg_channels) && eeg_channels(k) <= length(labels)
                eeg_names(k) = string(labels(eeg_channels(k)));
            else
                eeg_names(k) = "EEG " + string(k);
            end
        end
    end

    eeg_scale = zeros(1, eeg_count);

    for k = 1:eeg_count
        sig = eeg_matrix(:,k);
        sig = fillmissing(sig, 'linear', 'EndValues', 'nearest');
        sig = sig - median(sig, 'omitnan');

        s = std(sig, 'omitnan');

        if isnan(s) || s == 0
            s = 1;
        end

        eeg_scale(k) = s;
    end

    ecg_plot_base = fillmissing(ecg_display, 'linear', 'EndValues', 'nearest');
    ecg_plot_base = ecg_plot_base - median(ecg_plot_base, 'omitnan');

    ecg_scale = std(ecg_plot_base, 'omitnan');

    if isnan(ecg_scale) || ecg_scale == 0
        ecg_scale = 1;
    end

    vertical_gap = 5;
    eeg_offsets = ((eeg_count:-1:1) * vertical_gap);
    ecg_offset = 0;

    eeg_plot_matrix = zeros(n_samples, eeg_count);

    for k = 1:eeg_count
        y = eeg_matrix(:, k);
        y = fillmissing(y, 'linear', 'EndValues', 'nearest');
        y = y - median(y, 'omitnan');
        y = y ./ eeg_scale(k);
        y = y + eeg_offsets(k);
        eeg_plot_matrix(:, k) = y;
    end

    ecg_plot_vector = ecg_display;
    ecg_plot_vector = fillmissing(ecg_plot_vector, 'linear', 'EndValues', 'nearest');
    ecg_plot_vector = ecg_plot_vector - median(ecg_plot_vector, 'omitnan');
    ecg_plot_vector = ecg_plot_vector ./ ecg_scale;
    ecg_plot_vector = ecg_plot_vector + ecg_offset;

    fig = figure( ...
        'Name', sprintf('sub_%d EEG-only Review Viewer with Best Single ECG/EKG', sub_no), ...
        'Color', 'w', ...
        'Position', [80 40 1650 920], ...
        'NumberTitle', 'off', ...
        'Renderer', 'opengl');

    ax = axes('Parent', fig, 'Position', [0.06 0.16 0.90 0.76]);
    hold(ax, 'on');

    event_patch_handles = gobjects(0);
    eeg_lines = gobjects(eeg_count,1);

    for k = 1:eeg_count
        eeg_lines(k) = plot(ax, NaN, NaN, 'LineWidth', 0.8);
    end

    ecg_line = plot(ax, NaN, NaN, 'k', 'LineWidth', 1.1);

    xlabel(ax, 'Time (seconds)', 'Color', 'k');
    ylabel(ax, 'Channels', 'Color', 'k');

    title_handle = title(ax, ...
        sprintf('sub_%d EEG + selected best ECG/EKG review viewer', sub_no), ...
        'Color', 'k', ...
        'FontWeight', 'bold', ...
        'Interpreter', 'none');

    ytick_positions = [ecg_offset fliplr(eeg_offsets)];
    ytick_labels = ["BEST ECG/EKG: " + string(ecg_label); flipud(eeg_names(:))];

    yticks(ax, ytick_positions);
    yticklabels(ax, ytick_labels);

    ylim(ax, [-vertical_gap, max(eeg_offsets) + vertical_gap]);

    grid(ax, 'on');
    box(ax, 'on');
    setWhiteAxes(ax);

    uicontrol(fig, 'Style', 'pushbutton', 'String', '<< Back', ...
        'Units', 'normalized', 'Position', [0.06 0.055 0.075 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) moveView(-step_sec));

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Forward >>', ...
        'Units', 'normalized', 'Position', [0.145 0.055 0.075 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) moveView(step_sec));

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Zoom In', ...
        'Units', 'normalized', 'Position', [0.235 0.055 0.075 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) zoomView(0.60));

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Zoom Out', ...
        'Units', 'normalized', 'Position', [0.320 0.055 0.075 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) zoomView(1.60));

    uicontrol(fig, 'Style', 'text', 'String', 'Go to sec:', ...
        'Units', 'normalized', 'Position', [0.415 0.062 0.055 0.030], ...
        'BackgroundColor', 'w', 'ForegroundColor', 'k');

    jump_box = uicontrol(fig, 'Style', 'edit', 'String', num2str(start_time), ...
        'Units', 'normalized', 'Position', [0.475 0.058 0.065 0.038], ...
        'BackgroundColor', 'w', 'ForegroundColor', 'k');

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Jump', ...
        'Units', 'normalized', 'Position', [0.548 0.055 0.060 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) jumpToSecond());

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Save View PNG', ...
        'Units', 'normalized', 'Position', [0.625 0.055 0.100 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) saveCurrentView());

    uicontrol(fig, 'Style', 'pushbutton', 'String', 'Reset 100s', ...
        'Units', 'normalized', 'Position', [0.740 0.055 0.080 0.045], ...
        'FontWeight', 'bold', 'Callback', @(~,~) resetView());

    help_text = sprintf(['Mouse drag = pan | Mouse wheel = zoom | ', ...
        'Left/Right = move %.0f sec | Up/Down = zoom | S = save | ', ...
        'RED/YELLOW/GREEN = EEG-only event strength | ECG = selected best channel only'], step_sec);

    uicontrol(fig, 'Style', 'text', 'String', help_text, ...
        'Units', 'normalized', 'Position', [0.06 0.010 0.88 0.030], ...
        'BackgroundColor', 'w', 'ForegroundColor', 'k', 'HorizontalAlignment', 'left');

    is_dragging = false;
    drag_start_x = NaN;
    drag_start_view = NaN;
    last_drag_refresh_clock = tic;
    drag_refresh_gap_sec = 0.04;

    fig.WindowScrollWheelFcn = @mouseWheelZoom;
    fig.WindowButtonDownFcn = @startDrag;
    fig.WindowButtonMotionFcn = @dragPan;
    fig.WindowButtonUpFcn = @stopDrag;
    fig.WindowKeyPressFcn = @keyControl;

    refreshPlot();

    disp('====================================')
    disp('INTERACTIVE STACKED EEG + BEST ECG VIEWER')
    disp('BLACK = SELECTED BEST ECG/EKG DISPLAY')
    disp('ECG INPUT SHOULD BE ecg_display_clean')
    disp('SHADED WINDOWS: RED = very possible, YELLOW = suspicious, GREEN = weak review')
    disp('MOUSE DRAG = pan left/right')
    disp('MOUSE WHEEL = zoom in/out')
    disp('LEFT / RIGHT ARROW = move section')
    disp('UP / DOWN ARROW = zoom')
    disp('S = save current view')
    disp('====================================')

    function refreshPlot()
        view_width = max(min_view_width, min(max_view_width, view_width));
        view_width = min(view_width, total_duration);
        view_start = max(0, min(view_start, total_duration - view_width));
        view_end = min(total_duration, view_start + view_width);

        idx = find(t >= view_start & t <= view_end);

        if isempty(idx)
            return;
        end

        if length(idx) > max_display_points
            pick = round(linspace(1, length(idx), max_display_points));
            idx = idx(pick);
        end

        tx = t(idx);

        if ~isempty(event_patch_handles)
            delete(event_patch_handles(ishandle(event_patch_handles)));
        end

        event_patch_handles = gobjects(0);

        yl = [-vertical_gap, max(eeg_offsets) + vertical_gap];

        visible_events = find(event_ends >= view_start & event_starts <= view_end);

        for ep = 1:length(visible_events)
            k_event = visible_events(ep);

            s_event = max(event_starts(k_event), view_start);
            e_event = min(event_ends(k_event), view_end);

            if k_event <= length(event_status)
                [patch_color, line_color, face_alpha] = getEventMarkColors(event_status(k_event));
            else
                [patch_color, line_color, face_alpha] = getEventMarkColors("EVENT");
            end

            event_patch_handles(end+1) = patch(ax, ...
                [s_event e_event e_event s_event], ...
                [yl(1) yl(1) yl(2) yl(2)], ...
                patch_color, ...
                'FaceAlpha', face_alpha, ...
                'EdgeColor', 'none', ...
                'HandleVisibility', 'off');

            event_patch_handles(end+1) = xline(ax, event_starts(k_event), '-', ...
                'Color', line_color, ...
                'LineWidth', 1.1, ...
                'HandleVisibility', 'off');

            event_patch_handles(end+1) = xline(ax, event_ends(k_event), '-', ...
                'Color', line_color, ...
                'LineWidth', 1.1, ...
                'HandleVisibility', 'off');
        end

        if ~isempty(event_patch_handles)
            try
                uistack(event_patch_handles, 'bottom');
            catch
                % Ignore stacking issues in older MATLAB releases.
            end
        end

        for ch = 1:eeg_count
            set(eeg_lines(ch), 'XData', tx, 'YData', eeg_plot_matrix(idx, ch));
        end

        set(ecg_line, 'XData', tx, 'YData', ecg_plot_vector(idx));

        xlim(ax, [view_start view_end]);
        ylim(ax, yl);

        tick_start = ceil(view_start);
        tick_end = floor(view_end);
        dynamic_xtick_gap = max(xtick_gap_sec, ceil(view_width / 20));

        if tick_end > tick_start
            xticks(ax, tick_start:dynamic_xtick_gap:tick_end);
        end

        title_handle.String = sprintf( ...
            ['sub_%d EEG + BEST ECG/EKG viewer | %.2f to %.2f sec | Window %.2f sec | ', ...
             'ECG: %s | RED/YELLOW/GREEN = EEG-only windows'], ...
            sub_no, view_start, view_end, view_width, string(ecg_label));

        title_handle.Interpreter = 'none';

        jump_box.String = sprintf('%.2f', view_start);

        drawnow limitrate;
    end

    function moveView(amount_sec)
        view_start = view_start + amount_sec;
        view_start = max(0, min(view_start, total_duration - view_width));
        refreshPlot();
    end

    function zoomView(factor)
        xl = xlim(ax);
        center_time = mean(xl);

        new_width = view_width * factor;
        new_width = max(min_view_width, min(max_view_width, new_width));
        new_width = min(new_width, total_duration);

        view_width = new_width;
        view_start = center_time - view_width/2;
        view_start = max(0, min(view_start, total_duration - view_width));

        refreshPlot();
    end

    function jumpToSecond()
        jump_time = str2double(jump_box.String);

        if isnan(jump_time)
            warning('Invalid jump time. Enter a number in seconds.');
            jump_box.String = sprintf('%.2f', view_start);
            return;
        end

        view_start = max(0, min(jump_time, total_duration - view_width));
        refreshPlot();
    end

    function resetView()
        view_width = window_sec;
        view_start = start_time;
        view_start = max(0, min(view_start, total_duration - view_width));
        refreshPlot();
    end

    function mouseWheelZoom(~, event)
        cp = get(ax, 'CurrentPoint');
        mouse_x = cp(1,1);

        if mouse_x < view_start || mouse_x > view_start + view_width
            mouse_x = view_start + view_width/2;
        end

        old_width = view_width;

        if event.VerticalScrollCount > 0
            factor = 1.25;
        else
            factor = 0.80;
        end

        new_width = old_width * factor;
        new_width = max(min_view_width, min(max_view_width, new_width));
        new_width = min(new_width, total_duration);

        relative_pos = (mouse_x - view_start) / old_width;

        view_width = new_width;
        view_start = mouse_x - relative_pos * view_width;
        view_start = max(0, min(view_start, total_duration - view_width));

        refreshPlot();
    end

    function startDrag(~, ~)
        clicked_obj = hittest(fig);
        clicked_axes = ancestor(clicked_obj, 'axes');

        if isequal(clicked_obj, ax) || isequal(clicked_axes, ax)
            is_dragging = true;

            cp = get(ax, 'CurrentPoint');
            drag_start_x = cp(1,1);
            drag_start_view = view_start;
        end
    end

    function dragPan(~, ~)
        if ~is_dragging
            return;
        end

        cp = get(ax, 'CurrentPoint');
        current_x = cp(1,1);

        dx = drag_start_x - current_x;

        view_start = drag_start_view + dx;
        view_start = max(0, min(view_start, total_duration - view_width));

        if toc(last_drag_refresh_clock) < drag_refresh_gap_sec
            return;
        end

        last_drag_refresh_clock = tic;

        refreshPlot();
    end

    function stopDrag(~, ~)
        if is_dragging
            is_dragging = false;
            refreshPlot();
        end
    end

    function keyControl(~, event)
        switch event.Key
            case 'rightarrow'
                moveView(step_sec);

            case 'leftarrow'
                moveView(-step_sec);

            case 'uparrow'
                zoomView(0.75);

            case 'downarrow'
                zoomView(1.35);

            case 's'
                saveCurrentView();

            otherwise
                return;
        end
    end

    function saveCurrentView()
        view_end = min(total_duration, view_start + view_width);

        default_name = sprintf('sub_%d_BEST_ECG_Marked_Manual_View_%.2f_to_%.2f_sec.png', ...
            sub_no, view_start, view_end);

        [file_name, folder_name] = uiputfile( ...
            {'*.png', 'PNG Image (*.png)'}, ...
            'Save current EEG/ECG view as image', ...
            default_name);

        if isequal(file_name, 0)
            return;
        end

        save_path = fullfile(folder_name, file_name);

        try
            exportgraphics(ax, save_path, 'Resolution', 200, 'BackgroundColor', 'white');
            fprintf('Saved current viewer image: %s\n', save_path);
        catch
            warning('exportgraphics failed. Trying saveas full figure instead.');
            saveas(fig, save_path);
        end
    end
end


function eeg_channels = detectEEGChannelsFlexible(labels, original_labels)
    % Detect EEG channels even when EDF labels do not start with "EEG".
    % Example accepted labels:
    %   Fp2-AR, F8-AR, T4-AR, C3-A1, EEG Fp1, EEGFP1
    % Pure reference channels like A1-AR and A2-AR are excluded.

    labels = string(labels(:));
    original_labels = string(original_labels(:));

    if numel(original_labels) ~= numel(labels)
        original_labels = labels;
    end

    labels_upper = upper(strtrim(labels));
    original_upper = upper(strtrim(original_labels));

    clean_labels = upper(regexprep(labels_upper, '[^A-Z0-9]', ''));
    clean_original = upper(regexprep(original_upper, '[^A-Z0-9]', ''));

    clean_combined = clean_original;
    missing_original = strlength(clean_combined) == 0;
    clean_combined(missing_original) = clean_labels(missing_original);

    eeg_electrodes = [ ...
        "FP1", "FP2", ...
        "F7", "F8", "F3", "F4", "FZ", ...
        "FT7", "FT8", "FC3", "FC4", "FCZ", ...
        "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", ...
        "C3", "C4", "CZ", ...
        "TP7", "TP8", "CP3", "CP4", "CPZ", ...
        "P7", "P8", "P3", "P4", "PZ", ...
        "O1", "O2", "OZ" ...
    ];

    is_standard_eeg = false(size(clean_combined));

    for k = 1:numel(eeg_electrodes)
        electrode = eeg_electrodes(k);
        is_standard_eeg = is_standard_eeg | startsWith(clean_combined, electrode);
    end

    is_eeg_prefix = startsWith(labels_upper, "EEG") | startsWith(original_upper, "EEG") | ...
                    startsWith(clean_labels, "EEG") | startsWith(clean_original, "EEG");

    non_eeg_keywords = [ ...
        "ECG", "EKG", "HEART", "CARD", "HR", ...
        "RESP", "PHOTIC", "MARK", "ANNOT", "EVENT", "TRIG", "STATUS", ...
        "EMG", "EOG", "PULSE", "PLETH", "SPO2", "SAO2", "DC", "AUX" ...
    ];

    not_real_eeg = false(size(clean_combined));

    for k = 1:numel(non_eeg_keywords)
        kw = non_eeg_keywords(k);
        not_real_eeg = not_real_eeg | contains(labels_upper, kw) | ...
                                    contains(original_upper, kw) | ...
                                    contains(clean_labels, kw) | ...
                                    contains(clean_original, kw);
    end

    % Exclude pure reference channels only.
    % This removes A1-AR / A2-AR and EEG A1 / EEG A2,
    % but keeps real EEG labels like C3-A1.
    clean_without_eeg_prefix = regexprep(clean_combined, '^EEG', '');

    pure_reference = startsWith(clean_combined, "A1") | ...
                     startsWith(clean_combined, "A2") | ...
                     startsWith(clean_combined, "M1") | ...
                     startsWith(clean_combined, "M2") | ...
                     startsWith(clean_without_eeg_prefix, "A1") | ...
                     startsWith(clean_without_eeg_prefix, "A2") | ...
                     startsWith(clean_without_eeg_prefix, "M1") | ...
                     startsWith(clean_without_eeg_prefix, "M2") | ...
                     clean_combined == "REF" | ...
                     clean_combined == "GND" | ...
                     clean_combined == "AR";

    eeg_mask = (is_eeg_prefix | is_standard_eeg) & ~not_real_eeg & ~pure_reference;

    eeg_channels = find(eeg_mask);
    eeg_channels = eeg_channels(:);
end

function ecg_channels = detectECGChannelsFlexible(labels, original_labels)
    % Detect ECG/EKG channels from label names only.
    % We do not guess ECG from EEG-looking labels because that can corrupt HR/HRV.

    labels = string(labels(:));
    original_labels = string(original_labels(:));

    if numel(original_labels) ~= numel(labels)
        original_labels = labels;
    end

    labels_upper = upper(strtrim(labels));
    original_upper = upper(strtrim(original_labels));

    clean_labels = upper(regexprep(labels_upper, '[^A-Z0-9]', ''));
    clean_original = upper(regexprep(original_upper, '[^A-Z0-9]', ''));

    ecg_keywords = ["ECG", "EKG", "HEART", "CARD", "HR", "PULSE", "PLETH"];
    ecg_mask = false(size(labels_upper));

    for k = 1:numel(ecg_keywords)
        kw = ecg_keywords(k);
        ecg_mask = ecg_mask | contains(labels_upper, kw) | ...
                              contains(original_upper, kw) | ...
                              contains(clean_labels, kw) | ...
                              contains(clean_original, kw);
    end

    ecg_channels = find(ecg_mask);
    ecg_channels = ecg_channels(:);
end

function [data, info, filename] = loadEDFFixReservedOnly(filename)
    % Loads EDF normally first. If MATLAB rejects only the Reserved header
    % field, create a copied EDF with only that 44-byte header field fixed.

    try
        data = edfread(filename);
        info = edfinfo(filename);
        return;
    catch ME
        is_reserved_error = contains(ME.message, 'Expected Reserved') || ...
                            contains(ME.message, 'validateEDF');

        if ~is_reserved_error
            rethrow(ME);
        end

        fprintf('\nEDF Reserved header field is non-standard. Creating fixed copy only for MATLAB loading...\n');
        fprintf('Original EDF is kept unchanged.\n');

        fixed_filename = fixEDFReservedField(filename, '');

        try
            data = edfread(fixed_filename);
            info = edfinfo(fixed_filename);
            filename = fixed_filename;
            fprintf('Fixed EDF loaded successfully using blank Reserved field.\n');
            return;
        catch
            fixed_filename = fixEDFReservedField(filename, 'EDF+C');
            data = edfread(fixed_filename);
            info = edfinfo(fixed_filename);
            filename = fixed_filename;
            fprintf('Fixed EDF loaded successfully using EDF+C Reserved field.\n');
        end
    end
end

function fixedFile = fixEDFReservedField(originalFile, reservedValue)
    % EDF fixed header Reserved field starts at byte 193 in the EDF spec.
    % MATLAB fseek uses 0-based offset, so the offset is 192.
    % Field length is 44 bytes. Signal data is not changed.

    [folderPath, baseName, ext] = fileparts(originalFile);

    if isempty(reservedValue)
        suffix = '_fixed_blank_reserved';
    else
        suffix = ['_fixed_' reservedValue '_reserved'];
        suffix = strrep(suffix, '+', 'plus');
    end

    fixedFile = fullfile(folderPath, [baseName suffix ext]);

    copyfile(originalFile, fixedFile, 'f');

    fid = fopen(fixedFile, 'r+', 'ieee-le');

    if fid < 0
        error('Could not open copied EDF file for Reserved header fixing.');
    end

    cleaner = onCleanup(@() fclose(fid));

    reservedBytes = repmat(uint8(' '), 1, 44);

    if ~isempty(reservedValue)
        tag = uint8(reservedValue);
        reservedBytes(1:numel(tag)) = tag;
    end

    fseek(fid, 192, 'bof');
    fwrite(fid, reservedBytes, 'uint8');
end

