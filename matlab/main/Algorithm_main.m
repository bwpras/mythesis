%% Algorithm Experiment 2
% Data retrivement
% Load the data to analyze
% Should we do it in real time?

% This need Nodo.mat file that has Labeled Sensor as MBP, BC, WV
% else it might not work

clear; close all; clc;
paths = startup();
% load('.\Nodo.mat')
[file,path] = uigetfile('*.mat', 'Select a Nodo MAT file', paths.interim);
if isequal(file,0)
    disp('User selected Cancel');
else
    fullFileName = fullfile(path, file);
    S = load(fullFileName);  % Loads variables directly into workspace
    disp(['Loaded file: ', fullFileName]);
end

if isfield(S,'Nodo_filtered')
    Nodo_filtered = S.Nodo_filtered;
elseif isfield(S,'Nodo')
    Nodo_filtered = S.Nodo;
else
    warning('File %s has neither Nodo_filtered nor Nodo. Skipping.', file);
end
Test = Nodo_filtered;
Resample = false;
plotFigure = true;
runAnalysis = true;

%% Filtering

% Filtering parameters
Fs = 40;                                     % Sampling frequency
fc = 1;                                      % Butterworth cut-off frequency
dt = 1 / Fs;                                 % Temporal interval
filterOrder = 1;                             % Butterworth filter order
windowSize = 20;                             % Moving avarage filter pressure window
windowGrad = 20;                             % Moving avarage filter gradient window
[b, a] = butter(filterOrder, fc / (Fs / 2)); % Butterworth filter coefficient

numTests = length(Test);

fc_buildup = 10;                                      % 10 Hz for buildup-only analysis
[b_buildup, a_buildup] = butter(filterOrder, fc_buildup/(Fs/2));
windowSize_buildup = 5; % shorter window for 10 Hz path

% [Test, hFig] = compare_causal_filters(Test, Fs, 5, 2);
% [Test, hFigPressure, hFigCurv] = compare_causal_filters_with_curvature(Test, Fs, 5, 2);
%% --- Data filtering ---
for j = 1:numTests
    N = length(Test(j).Time);

    % Allocate (original names)
    Test(j).Pressure_mean_filter        = zeros(N, 1);
    Test(j).Pressure_filter             = zeros(N, 1);
    Test(j).Gradient_pressure           = zeros(N, 1);
    Test(j).Gradient_pressure_filtered  = zeros(N, 1);

    % Allocate (10 Hz causal path)
    Test(j).Pressure_filter_10Hz             = zeros(N, 1);
    Test(j).Gradient_pressure_10Hz           = zeros(N, 1);
    Test(j).Gradient_pressure_filtered_10Hz  = zeros(N, 1);

    % Moving average buffers (pressure + 1 Hz gradient)
    movingSum         = 0;
    movingSum_grad    = 0;
    buffer            = zeros(windowSize, 1);
    buffer_grad       = zeros(windowGrad, 1);
    bufferIndex       = 1;
    bufferIndex_grad  = 1;

    % Moving average buffer (10 Hz gradient) — causal
    % buffers before the loop
    movingSum10   = 0;
    buffer10      = zeros(windowSize_buildup,1);
    bufferIdx10   = 1;
    movingSum_grad10      = 0;
    % buffer_grad10         = zeros(windowGrad_buildup, 1);
    bufferIndex_grad10    = 1;

    for c1 = 1:N
        % ===== Moving average on pressure (shared input for both paths) =====
        newVal = Test(j).Pressure(c1);
        movingSum = movingSum - buffer(bufferIndex) + newVal;
        buffer(bufferIndex) = newVal;
        bufferIndex = mod(bufferIndex, windowSize) + 1;
        Test(j).Pressure_mean_filter(c1) = movingSum / min(c1, windowSize);

        % ===== 1 Hz Butterworth (causal) =====
        if c1 == 1
            Test(j).Pressure_filter(c1) = b(1) * Test(j).Pressure_mean_filter(c1);
        else
            Test(j).Pressure_filter(c1) = b(1) * Test(j).Pressure_mean_filter(c1) + ...
                b(2) * Test(j).Pressure_mean_filter(c1-1) - ...
                a(2) * Test(j).Pressure_filter(c1-1);
        end

        % Gradient of 1 Hz pressure (causal backward diff)
        if c1 > 1
            Test(j).Gradient_pressure(c1) = ...
                (Test(j).Pressure_filter(c1) - Test(j).Pressure_filter(c1-1)) / dt;
        else
            Test(j).Gradient_pressure(c1) = 0;
        end

        % Moving average on 1 Hz gradient (causal)
        newVal_grad = Test(j).Gradient_pressure(c1);
        movingSum_grad = movingSum_grad - buffer_grad(bufferIndex_grad) + newVal_grad;
        buffer_grad(bufferIndex_grad) = newVal_grad;
        bufferIndex_grad = mod(bufferIndex_grad, windowGrad) + 1;
        Test(j).Gradient_pressure_filtered(c1) = movingSum_grad / min(c1, windowGrad);

        % ===== 10 Hz Butterworth (causal) — SAME LOOP PATTERN =====
        % inside the c1 loop, before 10 Hz filter
        newVal10 = Test(j).Pressure(c1);
        movingSum10 = movingSum10 - buffer10(bufferIdx10) + newVal10;
        buffer10(bufferIdx10) = newVal10;
        bufferIdx10 = mod(bufferIdx10, windowSize_buildup) + 1;
        Pressure_mean_filter_10 = movingSum10 / min(c1, windowSize_buildup);

        % 10 Hz filter on the dedicated pre-smoothed signal
        if c1 == 1
            Test(j).Pressure_filter_10Hz(c1) = b_buildup(1) * Pressure_mean_filter_10;
        else
            Test(j).Pressure_filter_10Hz(c1) = ...
                b_buildup(1) * Pressure_mean_filter_10 + ...
                b_buildup(2) * prev_Pressure_mean_filter_10 - ...
                a_buildup(2) * Test(j).Pressure_filter_10Hz(c1-1);
        end
        prev_Pressure_mean_filter_10 = Pressure_mean_filter_10;

        % % Causal moving average on 10 Hz gradient
        % g10_new = Test(j).Gradient_pressure_10Hz(c1);
        % movingSum_grad10 = movingSum_grad10 - buffer_grad10(bufferIndex_grad10) + g10_new;
        % buffer_grad10(bufferIndex_grad10) = g10_new;
        % bufferIndex_grad10 = mod(bufferIndex_grad10, windowGrad_buildup) + 1;
        % Test(j).Gradient_pressure_filtered_10Hz(c1) = ...
        %     movingSum_grad10 / min(c1, windowGrad_buildup);
    end
end


%% --- Find all BC sensors ---
isBC = arrayfun(@(s) isfield(s,'Label') && strcmpi(string(s.Label),'BC'), Test);
bcRows = find(isBC);

if isempty(bcRows)
    error('No sensors with Label == "BC" found.');
end

% --- Choose which BC index to plot ---
bcIdx = 3;   % change this to 2, 3, ... if multiple BC sensors exist

if bcIdx < 1 || bcIdx > numel(bcRows)
    error('bcIdx must be between 1 and %d.', numel(bcRows));
end

s = Test(bcRows(bcIdx));

% --- Check fields ---
requiredFields = ["Time","Pressure","Pressure_filter","Pressure_filter_10Hz"];
for f = requiredFields
    if ~isfield(s,f) || isempty(s.(f))
        error('Missing or empty field "%s" in selected BC sensor.', f);
    end
end

% --- Prepare data ---
tmbp = Test(1).Time;
pMBP = Test(1).Pressure_filter;
t  = s.Time(:);
p0 = s.Pressure(:);
p1 = s.Pressure_filter(:);
pH = s.Pressure_filter_10Hz(:);

% --- Downsample 10 Hz–filtered signal to 20 Hz and overlay ---
Ds = 2;                 % decimation factor: 40 Hz -> 20 Hz
Fs_new = Fs / Ds;       % 20 Hz
% Option B (built-in anti-aliasing IIR; robust even if fc were a bit high):
pH_ds = decimate(pH, Ds);           % MATLAB applies LPF + downsample
t_ds  = t(1:Ds:numel(pH));          % align timestamps

% % Align lengths
% L = min([numel(t), numel(p0), numel(p1), numel(pH)]);
% t  = t(1:L);
% pMBP1 = pMBP(1:L);
% p0 = p0(1:L);
% p1 = p1(1:L);
% pH = pH(1:L);
% 
% % Optional thinning for very large arrays
% MaxPoints = 250000;
% if L > MaxPoints
%     step = ceil(L/MaxPoints);
%     idx = 1:step:L;
%     t  = t(idx);
%     p0 = p0(idx);
%     p1 = p1(idx);
%     pH = pH(idx);
%     pMBP1 = pMBP1(idx);
% end

% --- Plot ---
figure('Name','BC Pressure Filters','Color','w'); hold on; grid on;
plot(tmbp, pMBP, 'k--','LineWidth',0.1,'DisplayName','Pressure (MBP)');
plot(t, p0, 'k--','LineWidth',0.1,'DisplayName','Pressure (raw)');
plot(t, p1, 'b-', 'LineWidth',1.2, 'DisplayName','Pressure\_filter (1 Hz)');
plot(t, pH, 'r-', 'LineWidth',0.8, 'DisplayName','Pressure\_filter\_10Hz');
plot(t_ds, pH_ds, 'mo', 'LineWidth', 0.5, 'MarkerSize', 3, ...
     'DisplayName', 'Pressure\_filter\_10Hz @ 20 Hz (downsampled)');
hold off
xlabel('Time');
ylabel('Pressure [bar]');
title(sprintf('BC Pressure & Filters — ID %s', string(s.ID)), 'Interpreter','none');
legend('Location','best');
xlim([t(1) t(end)]);
%% BRAKING PHASE
clc
% [TestBrake, ~, ~] = detect_braking_struct_beta(Test);
% [TestBrake, ~, ~] = detect_brakingaction_samples(Test);
[TestBrake, ~, ~] = Algorithm_BrakingDetection_test(Test);

%% ===== MBP & BC (with WV overlay) — Pressure only (linked x) =====
assert(exist('Test','var')==1 && ~isempty(Test), 'Missing Test.');
assert(exist('TestBrake','var')==1 && ~isempty(TestBrake), 'Missing TestBrake.');

% -------- colors (avoid red for defaults) --------
colMBPbg = [0.70 0.70 0.70];   % MBP base
colBCbg  = [0.85 0.85 0.85];   % BC base
colMBPok = [0.00 0.45 0.74];   % MBP phase

% -------- find rows in Test --------
jMBP = NaN; bc_rows = []; wv_rows = [];
for i = 1:numel(Test)
    if isfield(Test(i),'Label')
        L = upper(strtrim(string(Test(i).Label)));
        if strcmp(L,'MBP'), jMBP = i; end
        if startsWith(L,"BC"), bc_rows(end+1) = i; end
        if startsWith(L,"WV"), wv_rows(end+1) = i; end
    end
end
assert(~isnan(jMBP),'No MBP in Test.');
nBC = numel(bc_rows);
nWV = numel(wv_rows);

% -------- get IDs directly from Test (per physical sensor) --------
bcIDs = strings(nBC,1);
for r = 1:nBC
    bcIDs(r) = extractIDFromTestSensor(Test(bc_rows(r)));
end

wvIDs = strings(nWV,1);
for r = 1:nWV
    wvIDs(r) = extractIDFromTestSensor(Test(wv_rows(r)));
end

% -------- fixed colormaps per sensor index --------
bcColors = lines(max(nBC,1));
bcColors = bcColors(1:nBC,:);              % one color per BC sensor

wvColors = parula(max(nWV,1));
wvColors = wvColors(1:nWV,:);              % one color per WV sensor

% legend collections (one handle per sensor index)
bcLegendHandles = gobjects(nBC,1);
wvLegendHandles = gobjects(nWV,1);

% -------- figure & layout --------
figure('Color','w','Name','MBP & BC (WV overlaid) — Pressure only');
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

% (1) MBP Pressure
ax1 = nexttile; hold on; grid on;

% base (gray)
if isfield(Test(jMBP),'Time') && isfield(Test(jMBP),'Pressure_filter') && ...
        ~isempty(Test(jMBP).Time) && ~isempty(Test(jMBP).Pressure_filter)
    plot(Test(jMBP).Time, Test(jMBP).Pressure_filter,'-','Color',colMBPbg,'LineWidth',1.0);
end

% overlays from TestBrake
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'MBP_Time') || isempty(TestBrake(k).MBP_Time), continue; end
    if ~isfield(TestBrake(k),'MBP_Pressure') || isempty(TestBrake(k).MBP_Pressure), continue; end

    plot(TestBrake(k).MBP_Time, TestBrake(k).MBP_Pressure,'-','Color',colMBPok,'LineWidth',1.6);
end
ylabel('MBP Pressure [bar]');
title('MBP — Pressure');

% ---- annotate PhaseIdx on MBP plot (45° rotation) ----
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'MBP_Time') || isempty(TestBrake(k).MBP_Time), continue; end
    if ~isfield(TestBrake(k),'MBP_Pressure') || isempty(TestBrake(k).MBP_Pressure), continue; end
    if ~isfield(TestBrake(k),'PhaseIdx'), continue; end

    tSeg = TestBrake(k).MBP_Time;
    pSeg = TestBrake(k).MBP_Pressure;

    xMid = tSeg(1) + (tSeg(end)-tSeg(1))/2;
    yPos = max(pSeg) + 0.1;  % offset above max pressure

    text(ax1, xMid, yPos, sprintf('%d', TestBrake(k).PhaseIdx), ...
        'Rotation',45, ...
        'HorizontalAlignment','center', ...
        'VerticalAlignment','bottom', ...
        'FontSize',8, ...
        'Color',[0 0 0]);
end

% (2) BC Pressure  (WV overlays here)
ax2 = nexttile; hold on; grid on;

% BC bases (gray)
for r = 1:nBC
    jr = bc_rows(r);
    if isfield(Test(jr),'Time') && isfield(Test(jr),'Pressure_filter') && ...
            ~isempty(Test(jr).Time) && ~isempty(Test(jr).Pressure_filter)
        plot(Test(jr).Time, Test(jr).Pressure_filter,'-','Color',colBCbg,'LineWidth',0.9);
    end
end

% BC overlays: assume TestBrake(k).BC(r) uses same order as bc_rows
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'BC') || isempty(TestBrake(k).BC), continue; end
    for r = 1:numel(TestBrake(k).BC)
        if r > nBC
            % safety: more BC in this phase than BC sensors found
            continue;
        end

        B = TestBrake(k).BC(r);
        if ~isfield(B,'Time') || isempty(B.Time) || ...
           ~isfield(B,'Pressure') || isempty(B.Pressure)
            continue;
        end

        c = bcColors(r,:);              % color bound to sensor index r
        sid = bcIDs(r);                 % ID also bound to sensor index r

        h = plot(B.Time, B.Pressure,'-','Color',c,'LineWidth',1.5);

        % store legend handle only once per sensor
        if ~isgraphics(bcLegendHandles(r))
            bcLegendHandles(r) = h;
        else
            h.Annotation.LegendInformation.IconDisplayStyle = 'off';
        end
    end
end

% WV overlays: assume TestBrake(k).WV(r) uses same order as wv_rows
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'WV') || isempty(TestBrake(k).WV), continue; end
    for r = 1:numel(TestBrake(k).WV)
        if r > nWV
            continue;
        end

        W = TestBrake(k).WV(r);
        if ~isfield(W,'Time') || isempty(W.Time) || ...
           ~isfield(W,'Pressure') || isempty(W.Pressure)
            continue;
        end

        c = wvColors(r,:);             % color bound to WV sensor index r
        sid = wvIDs(r);

        h = plot(W.Time, W.Pressure,'--','Color',c,'LineWidth',1.2);

        if ~isgraphics(wvLegendHandles(r))
            wvLegendHandles(r) = h;
        else
            h.Annotation.LegendInformation.IconDisplayStyle = 'off';
        end
    end
end

ylabel('BC / WV Pressure [bar]');
xlabel('Time');
title('BC — Pressure (WV overlaid)');

% -------- legend (one entry per physical sensor) --------
% Filter out empty handles
bcMask = isgraphics(bcLegendHandles);
wvMask = isgraphics(wvLegendHandles);

allHandles = [bcLegendHandles(bcMask); wvLegendHandles(wvMask)];
allLabels  = [bcIDs(bcMask);          wvIDs(wvMask)];

if ~isempty(allHandles)
    legend(ax2, allHandles, cellstr(allLabels), ...
           'Location','eastoutside', ...
           'Interpreter','none');
end

% -------- link & zoom to MBP span --------
linkaxes([ax1,ax2],'x');
tStart = []; tEnd = [];
for k = 1:numel(TestBrake)
    if isfield(TestBrake(k),'MBP_Time') && ~isempty(TestBrake(k).MBP_Time)
        if isempty(tStart), tStart = TestBrake(k).MBP_Time(1); end
        tEnd = TestBrake(k).MBP_Time(end);
    end
end
if ~isempty(tStart) && ~isempty(tEnd), xlim([tStart tEnd]); end



%% Correlating WV into BC by WV mean pressure and BC max pressure
% Splits Tests into N sets
% Find single reference braking phase that is complete to pair
% WV and BC based on WV mean pressure and BC max pressure
[refPhase, scores, report] = pick_reference_phase(TestBrake);
fprintf('The Reference Phase is %d\n', refPhase);
% If we can't find any, we collect good sensor data one by one
% from each row
HealthySensorList = Collect_Healthy_SensorData(TestBrake);
%% splits the sets into 1 MBP 1 BC 1 WV,
% save the pairing into a .mat file that will be used for next run from the same Dati folder
% (so Dati01 BC and WV pairing will always the same)
% might work or might not work (so far work with Dati01,
% as long as there is braking action in which all the sensor is working)
% if we can't find any perfect braking action we use the HealthySensorList

[TBsets, pairingTable, datasetKey, regFile, usedMethod] = ...
    build_TestBrake_sets(TestBrake, HealthySensorList, file, refPhase);

disp(pairingTable)


%% Feature Extraction Phase classification

% inside this is a separate core function to detect:
% 1. MBP braking subphases (detect_MBP_pipe_subphases.m)
% 2. BC braking subphases (detect_BC_cyl_subphases.m)
TBsets_out = Algorithm_phaseclassification(TBsets, ...
    'MBPArgs', {'GradStart', -0.05, 'GradRelease', 0.05, 'DistributorIdleThresh', 0.05}, ...
    'BCArgs',  {'GradStartPos', +0.05, 'GradReleaseNeg', -0.05, 'EndPressure', 0.40}, ...
    'Verbose', true);

for i = 1:numel(TBsets_out)
    eval(sprintf('TestBrake_%d = TBsets_out{i};', i));
end

%   TBsets{1} == "TestBrake 1"
%   TBsets{2} == "TestBrake 2"
%   TBsets{3} == "TestBrake 3"
%% Each is 1xNphase with original MBP fields + BC_* + WV_*.
S_cells = TBsets_out;  % just a shorter alias
nS = numel(S_cells);

% --- Collect fieldnames for each struct ---
fieldLists = cell(nS,1);
for k = 1:nS
    fieldLists{k} = fieldnames(S_cells{k});
end

% --- Build the union of all fields ---
allFields = unique(vertcat(fieldLists{:}));

% --- Show which fields are missing in each struct ---
fprintf('=== Field comparison across TBsets_out structs ===\n');
for k = 1:nS
    thisFields   = fieldLists{k};
    missingHere  = setdiff(allFields, thisFields);
    extraHere    = setdiff(thisFields, allFields);  % normally empty, but kept for clarity

    fprintf('\nStruct #%d:\n', k);
    fprintf('  #Fields: %d\n', numel(thisFields));

    if isempty(missingHere)
        fprintf('  Missing fields: (none)\n');
    else
        fprintf('  Missing fields:\n');
        for j = 1:numel(missingHere)
            fprintf('    - %s\n', missingHere{j});
        end
    end

    if ~isempty(extraHere)
        fprintf('  Extra fields (not in union):\n');
        for j = 1:numel(extraHere)
            fprintf('    + %s\n', extraHere{j});
        end
    end
end
%% Phase Classification Post Processing
% Obtain Total_power_efficiency and other features from the cell array
% TBsets_out is a 1xN (or MxN) cell array of TestBrake struct arrays
for c = 1:numel(TBsets_out)
    S = TBsets_out{c};
    if isempty(S) || ~isstruct(S), continue; end

    for i = 1:numel(S)
        
        % Initialize error flags to 0 (no error)
        S(i).MBP_Sensor_error = 0;
        S(i).MBP_PhaseClassification_error = 0;
        S(i).MBP_braketiming_error = 0;
        S(i).BC_PhaseClassification_error = 0;
        S(i).BC_braketiming_error = 0;
        
        % Check MBP_Sensor_error: InitPressure <= 0
        if isfield(S(i),'InitPressure') && ~isempty(S(i).InitPressure)
            if S(i).InitPressure <= 0
                S(i).MBP_Sensor_error = 1;
            end
        end
        
        % Check MBP_PhaseClassification_error: Brake_timing_pipe or Release_timing_pipe < 0.001 or NaN
        if isfield(S(i),'Brake_timing_pipe') && ~isempty(S(i).Brake_timing_pipe)
            if isnan(S(i).Brake_timing_pipe) || S(i).Brake_timing_pipe < 0.001
                S(i).MBP_PhaseClassification_error = 1;
            end
        end
        if isfield(S(i),'Release_timing_pipe') && ~isempty(S(i).Release_timing_pipe)
            if isnan(S(i).Release_timing_pipe) || S(i).Release_timing_pipe < 0.001
                S(i).MBP_PhaseClassification_error = 1;
            end
        end
        
        % Check BC_PhaseClassification_error: Brake_timing_cyl or Release_timing_cyl < 0.001 or NaN
        if isfield(S(i),'Brake_timing_cyl') && ~isempty(S(i).Brake_timing_cyl)
            if isnan(S(i).Brake_timing_cyl) || S(i).Brake_timing_cyl < 0.001
                S(i).BC_PhaseClassification_error = 1;
            end
        end
        if isfield(S(i),'Release_timing_cyl') && ~isempty(S(i).Release_timing_cyl)
            if isnan(S(i).Release_timing_cyl) || S(i).Release_timing_cyl < 0.001
                S(i).BC_PhaseClassification_error = 1;
            end
        end
        % Check MBP_braketiming_error: Brake_timing_pipe or Release_timing_pipe > 200
        if isfield(S(i),'Brake_timing_pipe') && ~isempty(S(i).Brake_timing_pipe)
            if S(i).Brake_timing_pipe > 200
                S(i).MBP_braketiming_error = 1;
            end
        end
        if isfield(S(i),'Release_timing_pipe') && ~isempty(S(i).Release_timing_pipe)
            if S(i).Release_timing_pipe > 200
                S(i).MBP_braketiming_error = 1;
            end
        end
        % Check BC_braketiming_error: Brake_timing_cyl or Release_timing_cyl > 200
        if isfield(S(i),'Brake_timing_cyl') && ~isempty(S(i).Brake_timing_cyl)
            if S(i).Brake_timing_cyl > 200
                S(i).BC_braketiming_error = 1;
            end
        end
        if isfield(S(i),'Release_timing_cyl') && ~isempty(S(i).Release_timing_cyl)
            if S(i).Release_timing_cyl > 200
                S(i).BC_braketiming_error = 1;
            end
        end
        % ================================
        %  SHIFT GPS TIME BY +2 HOURS
        % ================================
        % Always create the field first
        S(i).GPS_Time_shifted = [];   % or [] if you prefer

        if isfield(S(i),'GPS_Time') && ~isempty(S(i).GPS_Time)
            try
                S(i).GPS_Time_shifted = S(i).GPS_Time + hours(0);
            catch
                warning('GPS_Time conversion failed for element %d in cell %d', i, c);
            end
        end
        % ---------- Power efficiencies ----------
        % BPE = Brake_power_cyl / Brake_power_pipe
        BPE = NaN;
        if isfield(S(i),'Brake_power_cyl') && isfield(S(i),'Brake_power_pipe')
            if ~isempty(S(i).Brake_power_cyl) && ~isempty(S(i).Brake_power_pipe) && isnumeric(S(i).Brake_power_cyl) && isnumeric(S(i).Brake_power_pipe)
                BPE = S(i).Brake_power_cyl ./ S(i).Brake_power_pipe;
                if isscalar(S(i).Brake_power_pipe)
                    if S(i).Brake_power_pipe == 0, BPE(:) = NaN; end
                else
                    z = (S(i).Brake_power_pipe == 0); if any(z(:)), BPE(z) = NaN; end
                end
            end
        end
        S(i).Brake_Power_eff = BPE;

        % RPE = Release_power_cyl / Release_power_pipe
        RPE = NaN;
        if isfield(S(i),'Release_power_cyl') && isfield(S(i),'Release_power_pipe')
            if ~isempty(S(i).Release_power_cyl) && ~isempty(S(i).Release_power_pipe) && isnumeric(S(i).Release_power_cyl) && isnumeric(S(i).Release_power_pipe)
                RPE = S(i).Release_power_cyl ./ S(i).Release_power_pipe;
                if isscalar(S(i).Release_power_pipe)
                    if S(i).Release_power_pipe == 0, RPE(:) = NaN; end
                else
                    z = (S(i).Release_power_pipe == 0); if any(z(:)), RPE(z) = NaN; end
                end
            end
        end
        S(i).Release_power_eff = RPE;

        % --- Normal case: use your previous (BPE+RPE) & (BEE+REE) ---
        % Total_power_efficiency = BPE + RPE  (NaN-safe)
        Total_power_efficiency = NaN;
        if isnumeric(BPE) && isnumeric(RPE)
            if isscalar(BPE) && ~isscalar(RPE), BPE = BPE + zeros(size(RPE)); end
            if isscalar(RPE) && ~isscalar(BPE), RPE = RPE + zeros(size(BPE)); end
            bothNaN = isnan(BPE) & isnan(RPE);
            BPEz = BPE; BPEz(isnan(BPEz)) = 0;
            RPEz = RPE; RPEz(isnan(RPEz)) = 0;
            Total_power_efficiency  = BPEz + RPEz;
            Total_power_efficiency(bothNaN) = NaN;
            S(i).Total_power_efficiency = Total_power_efficiency;
        end

        % Calculate Normalized Total Power Efficiency 
        TPE = S(i).Total_power_efficiency;
        WV_mean = S(i).WV_MeanPressure;
        if ~isnan(TPE)
            S(i).Total_power_normalized = TPE*(S(i).Max_pressure_cyl/S(i).Max_pressure_pipe);
            if ~isnan(WV_mean)
                S(i).Total_power_weighted = S(i).Total_power_normalized / S(i).WV_MeanPressure;
            else
                S(i).Total_power_weighted = NaN;
            end
        else
            S(i).Total_power_normalized = NaN;
            S(i).Total_power_weighted = NaN;
        end
        % ---------- Energy efficiencies ----------
        % BEE = Brake_energy_cyl / Brake_energy_pipe
        BEE = NaN;
        if isfield(S(i),'Brake_energy_cyl') && isfield(S(i),'Brake_energy_pipe')
            if ~isempty(S(i).Brake_energy_cyl) && ~isempty(S(i).Brake_energy_pipe) && isnumeric(S(i).Brake_energy_cyl) && isnumeric(S(i).Brake_energy_pipe)
                BEE = S(i).Brake_energy_cyl ./ S(i).Brake_energy_pipe;
                if isscalar(S(i).Brake_energy_pipe)
                    if S(i).Brake_energy_pipe == 0, BEE(:) = NaN; end
                else
                    z = (S(i).Brake_energy_pipe == 0); if any(z(:)), BEE(z) = NaN; end
                end
            end
        end
        S(i).Brake_energy_eff = BEE;

        % REE = Release_energy_cyl / Release_energy_pipe
        REE = NaN;
        if isfield(S(i),'Release_energy_cyl') && isfield(S(i),'Release_energy_pipe')
            if ~isempty(S(i).Release_energy_cyl) && ~isempty(S(i).Release_energy_pipe) && isnumeric(S(i).Release_energy_cyl) && isnumeric(S(i).Release_energy_pipe)
                REE = S(i).Release_energy_cyl ./ S(i).Release_energy_pipe;
                if isscalar(S(i).Release_energy_pipe)
                    if S(i).Release_energy_pipe == 0, REE(:) = NaN; end
                else
                    z = (S(i).Release_energy_pipe == 0); if any(z(:)), REE(z) = NaN; end
                end
            end
        end
        S(i).Release_energy_eff = REE;

        % Total_power_efficiency = BEE + REE  (NaN-safe)
        Total_EN_eff = NaN;
        if isnumeric(BEE) && isnumeric(REE)
            if isscalar(BEE) && ~isscalar(REE), BEE = BEE + zeros(size(REE)); end
            if isscalar(REE) && ~isscalar(BEE), REE = REE + zeros(size(BEE)); end
            bothNaN = isnan(BEE) & isnan(REE);
            BEEz = BEE; BEEz(isnan(BEEz)) = 0;
            REEz = REE; REEz(isnan(REEz)) = 0;
            Total_EN_eff  = BEEz + REEz;
            Total_EN_eff(bothNaN) = NaN;
            S(i).Total_EN_eff = Total_EN_eff;
        end

        % ==============================================================
        %     CONDITIONAL: NORMAL vs NON STANDARD CASE (CYL)
        % ==============================================================
        % --- More generic metric, use totals ---

        % Compute total pipe power/energy
        Power_MBP = S(i).Total_power_pipe;
        Energy_MBP = S(i).Total_energy_pipe;
        if isempty(Power_MBP) || Power_MBP==0, Power_MBP = NaN; end
        if isempty(Energy_MBP) || Energy_MBP==0, Energy_MBP = NaN; end

        % Compute only brake cylinder contributions
        Power_BC = S(i).Total_power_cyl;
        Energy_BC = S(i).Total_energy_cyl;

        % Ratios
        S(i).Power_ratio = Power_BC ./ Power_MBP;
        S(i).Energy_ratio = Energy_BC ./ Energy_MBP;

        % ==============================================================
        %                    Power delays
        % ==============================================================
        % Brake Power Delay = Brake_power_cyl - Brake_power_pipe
        Brake_power_delay = NaN;
        if ~isempty(S(i).Brake_power_cyl) && ~isempty(S(i).Brake_power_pipe) && isnumeric(S(i).Brake_power_cyl) && isnumeric(S(i).Brake_power_pipe)
            Brake_power_delay = S(i).Brake_power_cyl - S(i).Brake_power_pipe;
        end
        S(i).Brake_power_delay = Brake_power_delay;

        % Release Power Delay = Release_power_cyl - Release_power_pipe
        Release_power_delay = NaN;
        if ~isempty(S(i).Release_power_cyl) && ~isempty(S(i).Release_power_pipe) && isnumeric(S(i).Release_power_cyl) && isnumeric(S(i).Release_power_pipe)
            Release_power_delay = S(i).Release_power_cyl - S(i).Release_power_pipe;
        end
        S(i).Release_power_delay = Release_power_delay;

        % Total Power Delay
        % Abnormal case: Brake_power_cyl - Total_power_pipe
        % if S(i).Non_Standard_Braking == 1
        %     % total power on pipe: prefer stored total, else sum components
        %     Total_Power_MBP = S(i).Total_power_pipe;
        %     Total_Power_BC = S(i).Total_power_cyl;
        %     if isempty(Total_Power_MBP) || ~isfinite(Total_Power_MBP), Total_Power_MBP = NaN; end
        %     S(i).Total_power_delay = Total_Power_BC - Total_Power_MBP;
        % else
        %     BPD = Brake_power_delay; RPD = Release_power_delay;
        %     TPD  = BPD + RPD;
        %     S(i).Total_power_delay = TPD;
        % end
        BPD = Brake_power_delay; RPD = Release_power_delay;
        TPD  = BPD + RPD;
        S(i).Total_power_delay = TPD;

        % ==============================================================
        %           Pressure delays (unchanged)
        % ==============================================================
        % Buildup end pressure delay
        Buildup_end_pressure_delay = NaN;
        if isfield(S(i),'Buildup_pressure_cyl') && isfield(S(i),'Buildup_pressure_pipe')
            Buildup_press_cyl = S(i).Buildup_pressure_cyl;
            Buildup_press_pipe = S(i).Buildup_pressure_pipe;
            if isnumeric(Buildup_press_cyl) && ~isempty(Buildup_press_cyl) && ...
                    isnumeric(Buildup_press_pipe) && ~isempty(Buildup_press_pipe)
                Buildup_end_pressure_delay = Buildup_press_cyl(end) - Buildup_press_pipe(end);
            end
        end
        S(i).Buildup_end_pressure_delay = Buildup_end_pressure_delay;

        % Release start pressure delay
        Release_start_pressure_delay = NaN;
        if isfield(S(i),'Release_pressure_cyl') && isfield(S(i),'Release_pressure_pipe')
            Release_press_cyl = S(i).Release_pressure_cyl;
            Release_press_pipe = S(i).Release_pressure_pipe;
            if isnumeric(Release_press_cyl) && ~isempty(Release_press_cyl) && ...
                    isnumeric(Release_press_pipe) && ~isempty(Release_press_pipe)
                Release_start_pressure_delay = Release_press_cyl(1) - Release_press_pipe(1);
            end
        end
        S(i).Release_start_pressure_delay = Release_start_pressure_delay;
    end
    % No hard filtering - errors are now flagged in error fields
    TBsets_out{c} = S;  % write back
end



%%
% --- 1) Choose the fields to keep ---
keepFields = { ...
    'PhaseIdx','MBP_ID', 'BC_ID', 'WV_ID','GPS_NumSamples', ...
    'Start_brake_time_pipe','End_brake_time_pipe','Brake_timing_pipe','Brake_energy_pipe','Brake_power_pipe', ...
    'Start_buildup_time_pipe','End_buildup_time_pipe','Start_release_time_pipe','End_release_time_pipe', ...
    'Buildup_timing_pipe','Buildup_gradient_pipe','Buildup_energy_pipe','Buildup_power_pipe', ...
    'Holding_timing_pipe','Holding_energy_pipe','Holding_power_pipe', ...
    'Release_timing_pipe','Release_gradient_pipe','Release_energy_pipe','Release_power_pipe', ...
    'Max_pressure_pipe','Mean_pipe','Std_pipe', ...
    'Start_brake_time_cyl','End_brake_time_cyl','Brake_timing_cyl','Brake_energy_cyl','Brake_power_cyl', ...
    'Buildup_timing_cyl','Buildup_gradient_cyl','Buildup_energy_cyl','Buildup_power_cyl', ...
    'Holding_timing_cyl','Holding_energy_cyl','Holding_power_cyl', ...
    'Release_timing_cyl','Release_gradient_cyl','Release_energy_cyl','Release_power_cyl', ...
    'WV_MeanPressure', 'BC_MaxPressure', 'Max_pressure_cyl', ...
    'First_phase_error','First_phase_timing','First_phase_timing_half', ...
    'First_phase_half_time_ratio','First_phase_first_gradient','First_phase_mean_curvature', ...
    'First_phase_max_gradient','First_phase_inflection_point','First_phase_energy','First_phase_power',...
    'First_phase_timing_1hz','First_phase_timing_half_1hz', ...
    'First_phase_half_time_ratio_1hz','First_phase_first_gradient_1hz','First_phase_mean_curvature_1hz', ...
    'First_phase_max_gradient_1hz','First_phase_inflection_point_1hz','First_phase_energy_1hz','First_phase_power_1hz',...    
    'Start_brake_speed','End_brake_speed','Speed_difference','Speed_gradient', ...
    'Consecutive_braking_pipe', 'BC_BadStart', 'BC_NormalBraking','BC_LowBraking',...
    'BC_StartAboveThresh','BC_FlatStartNearZero','BC_AlreadyEngagedStart','BC_ReleasingAtStart',...
    'Total_power_efficiency','Total_EN_eff','Power_ratio','Energy_ratio', ...
    'Total_power_pipe', 'Total_power_cyl', 'EmergencyBrake_action',...
    'Brake_power_delay','Release_power_delay','Total_power_delay', ...
    'Buildup_end_pressure_delay','Release_start_pressure_delay', ...
    'Total_power_normalized', 'Total_power_weighted', ...
    'Brake_action_cyl','EmergencyBrake', 'Non_Standard_Braking', ...
    'MBP_PhaseClassification_error','BC_PhaseClassification_error', ...
    'MBP_braketiming_error','BC_braketiming_error', ...
    'SV_Error','UB_Error','UR_Error','DS_Error', ...
    'MBP_Sensor_error','BC_SensorError','WV_SensorError', ...
    'GPS_SensorError','Gateway_VB_Error','Gateway_CB_Error' ...
    };
%% --- Save TBsets_out using same base filename ---
TBsets_out_concat_struct = horzcat(TBsets_out{:});
% --- Save TBsets_out into a centralized DataOutput folder ---
if ~exist('file','var') || ~(ischar(file) || isstring(file))
    error('Variable "file" must exist and be a char or string filename/path.');
end

% Filter out records with any errors from struct array
% Keep only elements where all error flags are 0
validRows = arrayfun(@(x) x.MBP_Sensor_error == 0 & ...
                           x.MBP_PhaseClassification_error == 0 & ...
                           x.MBP_braketiming_error == 0 & ...
                           x.BC_PhaseClassification_error == 0 & ...
                           x.BC_braketiming_error == 0 & ...
                           x.Non_Standard_Braking == 0, ...
                     TBsets_out_concat_struct);

TestBrakes_Struct = TBsets_out_concat_struct(validRows);

[~, baseFile, ~] = fileparts(char(file));

% Primary and fallback output directories
outDir = paths.features;
% Construct output file name
outputFile = fullfile(outDir, baseFile + "_output" + ".mat");

% Save variable
% save(outputFile, 'TBsets_out', '-v7.3');

% fprintf('Saved TBsets_out to: %s\n', outputFile);

% --- 2) Strip fields: for each cell, for each struct, remove everything not in keepFields ---
for c = 1:numel(TBsets_out)
    S = TBsets_out{c};
    if isempty(S) || ~isstruct(S), continue; end

    % rmfield works on struct arrays; compute removal set from the first element,
    % then apply to the whole array.
    fn_all = fieldnames(S);                          % fields present (union across array)
    removeThese = setdiff(fn_all, keepFields);       % everything NOT whitelisted

    if ~isempty(removeThese)
        S = rmfield(S, removeThese);                 % drops for all elements at once
    end

    % --- reorder fields to match keepFields order for readability ---
    % Only keep the ones that exist in S now, in the preferred order:
    fn_now = fieldnames(S);
    desiredOrder = intersect(keepFields, fn_now, 'stable');
    S = orderfields(S, desiredOrder);

    TBsets_out_filtered{c} = S;   % write back
end



%% Combine every run into a Unified Table
TestBrakes_table = horzcat(TBsets_out_filtered{:});
[~, sortIdx] = sort([TestBrakes_table.Start_brake_time_pipe]);
TestBrakes_sorted = TestBrakes_table(sortIdx);
TestBrakes_table = struct2table(TestBrakes_sorted);
% Reorder the table columns based on keepFields
TestBrakes_table = TestBrakes_table(:, keepFields);
%%
% --- Auto-fill metadata from workspace variable "file" ---
if ~exist('file','var') || ~(ischar(file) || isstring(file))
    error('Variable "file" must be a char or string filename/path.');
end

% Normalize to char for fileparts, then convert to string for concatenation
[fileDir, baseFile, ext] = fileparts(char(file));
RunFile = string(baseFile) + string(ext);   % e.g., "Nodo_Dati10_20250616_20250618.mat"

% Try to get "DatiXX" from the filename first
tokens = regexp(baseFile, 'Nodo_(Dati\d+)_', 'tokens', 'once');

if ~isempty(tokens)
    RunFolder = string(tokens{1});          % "Dati10"
else
    % Fallback: search the directory path for DatiXX
    tokens2 = regexp(fileDir, '(Dati\d+)', 'tokens', 'once');
    if ~isempty(tokens2)
        RunFolder = string(tokens2{1});
    else
        RunFolder = "Unknown";
    end
end

% Attach to the table
TestBrakes_table.RunFile   = repmat(RunFile,   height(TestBrakes_table), 1);
TestBrakes_table.RunFolder = repmat(RunFolder, height(TestBrakes_table), 1);

% Insert into master (keeps one copy only, sorted by Start_brake_time)
% **The idea is that to have a compilation of database of every run that have
% been done (can be from Dati01, Dati05, or whatever) into a single
% spreadsheet/table**
% still in progress so might not work well,
% but can be reset by deleting the .mat file
% TestBrake_Master = update_brake_master( ...
%     TestBrakes_table, ...                 % your per-run table
%     'AllRunPath',      'TestBrake_Master.mat', ...
%     'PerFolderPattern','%s_Master.mat', ...   % -> 'Dati10_Master.mat', etc.
%     'WriteCSV',        false ...              % set true to also emit CSV files
% );
%% Clean up data
% Filter out records with any errors (single combined filter)
validRows = TestBrakes_table.MBP_Sensor_error == 0 & ...
            TestBrakes_table.MBP_PhaseClassification_error == 0 & ...
            TestBrakes_table.MBP_braketiming_error == 0 & ...
            TestBrakes_table.BC_PhaseClassification_error == 0 & ...
            TestBrakes_table.BC_braketiming_error == 0 & ...
            TestBrakes_table.Non_Standard_Braking == 0;

TestBrakes_table_clean = TestBrakes_table(validRows, :);
Testbrake_Standard = TestBrakes_table(TestBrakes_table.Non_Standard_Braking==0,:);
Testbrake_NonStandard = TestBrakes_table(TestBrakes_table.Non_Standard_Braking==1,:);
%% Run analysis for Total_power_efficiency
% --- Filter the table ---
TB_filteredtable = TestBrakes_table(TestBrakes_table.Non_Standard_Braking == 0, :);

% --- Extract the Total_power_efficiency column ---
Total_Power_eff_data = TB_filteredtable.Total_power_efficiency;
Total_Power_eff_data = Total_Power_eff_data(:);
Total_Power_eff_data = Total_Power_eff_data(isfinite(Total_Power_eff_data)); % remove NaN/Inf

% % --- Plot histogram with Gaussian fit ---
% figure;
% histfit(Total_Power_eff_data, 30, 'normal');   % 30 bins, normal (Gaussian) fit
% xlabel('Total Power Efficiency (Total_power_efficiency)');
% ylabel('Count');
% title('Gaussian Distribution of Total_power_efficiency for brake\_action\_cyl = 1');
% grid on;

% --- Fit Normal and compute 95% threshold ---
mu    = mean(Total_Power_eff_data);
sigma = std(Total_Power_eff_data);
Total_Power_eff_95pct_threshold = mu - 1.645 * sigma;     % 95th percentile if Normal
Total_Power_eff_empirical_95pct = prctile(Total_Power_eff_data, 95);
% figure; qqplot(Total_Power_eff_data); grid on; title('Q-Q plot of baseline Total_power_efficiency');
[h_ks,p_ks] = kstest((Total_Power_eff_data - mu)/sigma);  % H=1 means non-normal at alpha=0.05
fprintf('KS test vs Normal: H=%d, p=%.4g\n', h_ks, p_ks);
% --- Pick a working threshold ---
Total_Power_eff_threshold = Total_Power_eff_95pct_threshold;    % or use empirical if QQ/KS looks non-normal
% --- Estimate expected false positive rate on baseline ---
fp_rate_est = mean(Total_Power_eff_data < Total_Power_eff_threshold);
fprintf('Estimated false-positive rate on baseline: %.2f%%\n', 100 * fp_rate_est);

% --- Apply to new data (flag suspected leakage) ---
TB_filteredtable.LeakageFlag = TB_filteredtable.Total_power_efficiency < Total_Power_eff_threshold;

%% ===== Figure plotting & comparison ===
% %% ===== MBP & BC (with WV overlay) — Pressure & Gradient (linked x) =====
% assert(exist('Test','var')==1 && ~isempty(Test), 'Missing Test.');
% assert(exist('TestBrake','var')==1 && ~isempty(TestBrake), 'Missing TestBrake.');
% 
% % -------- colors (avoid red for defaults) --------
% colErr   = [0.85 0.10 0.10];   % errors only
% colMBPbg = [0.70 0.70 0.70];   % MBP base
% colBCbg  = [0.85 0.85 0.85];   % BC base
% colMBPok = [0.00 0.45 0.74];   % MBP phase
% % palettes for BC & WV overlays
% bcMap = parula(12); bcMap = bcMap(2:end-1,:);   % avoid extremes
% wvMap = lines(12);
% 
% % -------- find rows in Test --------
% jMBP = NaN; bc_rows = []; wv_rows = [];
% for i = 1:numel(Test)
%     if isfield(Test(i),'Label')
%         L = upper(strtrim(string(Test(i).Label)));
%         if strcmp(L,'MBP'), jMBP = i; end
%         if startsWith(L,"BC"), bc_rows(end+1) = i; end
%         if startsWith(L,"WV"), wv_rows(end+1) = i; end
%     end
% end
% assert(~isnan(jMBP),'No MBP in Test.');
% nBC = numel(bc_rows);
% nWV = numel(wv_rows);
% 
% % -------- figure & layout --------
% figure('Color','w','Name','MBP & BC (WV overlaid) — Pressure & Gradient');
% tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
% 
% % (1) MBP Pressure
% ax1 = nexttile; hold on; grid on;
% % base (gray)
% plot(Test(jMBP).Time, Test(jMBP).Pressure_filter,'-','Color',colMBPbg,'LineWidth',1.0);
% 
% % overlays
% for k = 1:numel(TestBrake)
%     if ~isfield(TestBrake(k),'MBP_Time') || isempty(TestBrake(k).MBP_Time), continue; end
%     c = colMBPok;
%     if isfield(TestBrake(k),'SV_Error') && TestBrake(k).SV_Error, c = colErr; end
%     plot(TestBrake(k).MBP_Time, TestBrake(k).MBP_Pressure,'-','Color',c,'LineWidth',1.6);
% end
% ylabel('MBP Pressure [bar]'); title('MBP — Pressure');
% 
% % (2) MBP Gradient
% ax2 = nexttile; hold on; grid on;
% % base (gray)
% plot(Test(jMBP).Time, Test(jMBP).Gradient_pressure_filtered,'-','Color',colMBPbg,'LineWidth',1.0);
% 
% % overlays
% for k = 1:numel(TestBrake)
%     if ~isfield(TestBrake(k),'MBP_Gradient') || isempty(TestBrake(k).MBP_Gradient), continue; end
%     c = colMBPok;
%     if isfield(TestBrake(k),'SV_Error') && TestBrake(k).SV_Error, c = colErr; end
%     plot(TestBrake(k).MBP_Time, TestBrake(k).MBP_Gradient,'-','Color',c,'LineWidth',1.4);
% end
% ylabel('MBP dP/dt [bar/s]'); title('MBP — Gradient');
% 
% % (3) BC Pressure  (WV overlays here)
% ax3 = nexttile; hold on; grid on;
% % BC bases (gray)
% for r = 1:nBC
%     jr = bc_rows(r);
%     plot(Test(jr).Time, Test(jr).Pressure_filter,'-','Color',colBCbg,'LineWidth',0.8);
% 
% end
% % BC overlays
% for k = 1:numel(TestBrake)
%     if ~isfield(TestBrake(k),'BC') || isempty(TestBrake(k).BC), continue; end
%     for r = 1:numel(TestBrake(k).BC)
%         B = TestBrake(k).BC(r);
%         if ~isfield(B,'Time') || isempty(B.Time) || ~isfield(B,'Pressure'), continue; end
%         c = bcMap( mod(r-1,size(bcMap,1)) + 1 , : );
%         if isfield(B,'SensorError') && B.SensorError, c = colErr; end
%         plot(B.Time, B.Pressure,'-','Color',c,'LineWidth',1.5);
%     end
% end
% % WV overlays (on the same BC pressure axes)
% for k = 1:numel(TestBrake)
%     if ~isfield(TestBrake(k),'WV') || isempty(TestBrake(k).WV), continue; end
%     for r = 1:numel(TestBrake(k).WV)
%         W = TestBrake(k).WV(r);
%         if ~isfield(W,'Time') || isempty(W.Time) || ~isfield(W,'Pressure'), continue; end
%         c = wvMap( mod(r-1,size(wvMap,1)) + 1 , : );
%         if isfield(W,'WV_SensorError') && W.WV_SensorError, c = colErr; end
%         plot(W.Time, W.Pressure,'--','Color',c,'LineWidth',1.2); % dashed to distinguish WV
%     end
% end
% ylabel('BC / WV Pressure [bar]'); title('BC — Pressure (WV overlaid)');
% 
% % (4) BC Gradient
% ax4 = nexttile; hold on; grid on;
% % bases (gray)
% for r = 1:nBC
%     jr = bc_rows(r);
%     plot(Test(jr).Time, Test(jr).Gradient_pressure_filtered,'-','Color',colBCbg,'LineWidth',0.9);
% 
% end
% % overlays
% for k = 1:numel(TestBrake)
%     if ~isfield(TestBrake(k),'BC') || isempty(TestBrake(k).BC), continue; end
%     for r = 1:numel(TestBrake(k).BC)
%         B = TestBrake(k).BC(r);
%         if ~isfield(B,'Time') || isempty(B.Time) || ~isfield(B,'Gradient') || isempty(B.Gradient), continue; end
%         c = bcMap( mod(r-1,size(bcMap,1)) + 1 , : );
%         if isfield(B,'SensorError') && B.SensorError, c = colErr; end
%         plot(B.Time, B.Gradient,'-','Color',c,'LineWidth',1.3);
%     end
% end
% ylabel('BC dP/dt [bar/s]'); xlabel('Time'); title('BC — Gradient');
% 
% % -------- link & zoom to MBP span --------
% linkaxes([ax1,ax2,ax3,ax4],'x');
% tStart = []; tEnd = [];
% for k = 1:numel(TestBrake)
%     if isfield(TestBrake(k),'MBP_Time') && ~isempty(TestBrake(k).MBP_Time)
%         if isempty(tStart), tStart = TestBrake(k).MBP_Time(1); end
%         tEnd = TestBrake(k).MBP_Time(end);
%     end
% end
% if ~isempty(tStart) && ~isempty(tEnd), xlim([tStart tEnd]); end

%% ===== MBP & BC (with WV overlay) — Pressure only (linked x) =====
assert(exist('Test','var')==1 && ~isempty(Test), 'Missing Test.');
assert(exist('TestBrake','var')==1 && ~isempty(TestBrake), 'Missing TestBrake.');

% -------- colors (avoid red for defaults) --------
colErr   = [0.85 0.10 0.10];   % errors only
colMBPbg = [0.70 0.70 0.70];   % MBP base
colBCbg  = [0.85 0.85 0.85];   % BC base
colMBPok = [0.00 0.45 0.74];   % MBP phase
% palettes for BC & WV overlays
bcMap = parula(12); bcMap = bcMap(2:end-1,:);   % avoid extremes
wvMap = lines(12);

% -------- find rows in Test --------
jMBP = NaN; bc_rows = []; wv_rows = [];
for i = 1:numel(Test)
    if isfield(Test(i),'Label')
        L = upper(strtrim(string(Test(i).Label)));
        if strcmp(L,'MBP'), jMBP = i; end
        if startsWith(L,"BC"), bc_rows(end+1) = i; end
        if startsWith(L,"WV"), wv_rows(end+1) = i; end
    end
end
assert(~isnan(jMBP),'No MBP in Test.');
nBC = numel(bc_rows);

% -------- figure & layout --------
figure('Color','w','Name','MBP & BC (WV overlaid) — Pressure only');
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

% (1) MBP Pressure
ax1 = nexttile; hold on; grid on;
% base (gray)
if isfield(Test(jMBP),'Time') && isfield(Test(jMBP),'Pressure_filter') && ...
        ~isempty(Test(jMBP).Time) && ~isempty(Test(jMBP).Pressure_filter)
    plot(Test(jMBP).Time, Test(jMBP).Pressure_filter,'-','Color',colMBPbg,'LineWidth',1.0);
end

% overlays from TestBrake
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'MBP_Time') || isempty(TestBrake(k).MBP_Time), continue; end
    if ~isfield(TestBrake(k),'MBP_Pressure') || isempty(TestBrake(k).MBP_Pressure), continue; end
    c = colMBPok;
    if isfield(TestBrake(k),'SV_Error') && islogical(TestBrake(k).SV_Error) && TestBrake(k).SV_Error
        c = colErr;
    end
    plot(TestBrake(k).MBP_Time, TestBrake(k).MBP_Pressure,'-','Color',c,'LineWidth',1.6);
end
ylabel('MBP Pressure [bar]'); title('MBP — Pressure');

% (2) BC Pressure  (WV overlays here)
ax2 = nexttile; hold on; grid on;
% BC bases (gray)
for r = 1:nBC
    jr = bc_rows(r);
    if isfield(Test(jr),'Time') && isfield(Test(jr),'Pressure_filter') && ...
            ~isempty(Test(jr).Time) && ~isempty(Test(jr).Pressure_filter)
        plot(Test(jr).Time, Test(jr).Pressure_filter,'-','Color',colBCbg,'LineWidth',0.9);
    end
end

% BC overlays
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'BC') || isempty(TestBrake(k).BC), continue; end
    for r = 1:numel(TestBrake(k).BC)
        B = TestBrake(k).BC(r);
        if ~isfield(B,'Time') || isempty(B.Time) || ~isfield(B,'Pressure') || isempty(B.Pressure), continue; end
        c = bcMap( mod(r-1,size(bcMap,1)) + 1 , : );
        if isfield(B,'SensorError') && islogical(B.SensorError) && B.SensorError
            c = colErr;
        end
        plot(B.Time, B.Pressure,'-','Color',c,'LineWidth',1.5);
    end
end

% WV overlays (dashed) on the same BC pressure axes
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'WV') || isempty(TestBrake(k).WV), continue; end
    for r = 1:numel(TestBrake(k).WV)
        W = TestBrake(k).WV(r);
        if ~isfield(W,'Time') || isempty(W.Time) || ~isfield(W,'Pressure') || isempty(W.Pressure), continue; end
        c = wvMap( mod(r-1,size(wvMap,1)) + 1 , : );
        if isfield(W,'WV_SensorError') && islogical(W.WV_SensorError) && W.WV_SensorError
            c = colErr;
        end
        plot(W.Time, W.Pressure,'--','Color',c,'LineWidth',1.2); % dashed for WV
    end
end
ylabel('BC / WV Pressure [bar]'); xlabel('Time'); title('BC — Pressure (WV overlaid)');

% -------- link & zoom to MBP span --------
linkaxes([ax1,ax2],'x');
tStart = []; tEnd = [];
for k = 1:numel(TestBrake)
    if isfield(TestBrake(k),'MBP_Time') && ~isempty(TestBrake(k).MBP_Time)
        if isempty(tStart), tStart = TestBrake(k).MBP_Time(1); end
        tEnd = TestBrake(k).MBP_Time(end);
    end
end
if ~isempty(tStart) && ~isempty(tEnd), xlim([tStart tEnd]); end

%% ===== Setup and Assertions =====
assert(exist('Test','var')==1 && ~isempty(Test), 'Missing Test.');
assert(exist('TestBrake','var')==1 && ~isempty(TestBrake), 'Missing TestBrake.');

% Colors
colErr   = [0.85 0.10 0.10];
colMBPbg = [0.70 0.70 0.70];
colBCbg  = [0.85 0.85 0.85];
colMBPok = [0.00 0.45 0.74];
bcMap    = parula(12); bcMap = bcMap(2:end-1,:);
wvMap    = lines(12);

% Indexing
jMBP = NaN; bc_rows = []; wv_rows = [];
for i = 1:numel(Test)
    if isfield(Test(i),'Label')
        L = upper(strtrim(string(Test(i).Label)));
        if strcmp(L,'MBP'), jMBP = i; end
        if startsWith(L,"BC"), bc_rows(end+1) = i; end
        if startsWith(L,"WV"), wv_rows(end+1) = i; end
    end
end
assert(~isnan(jMBP),'No MBP in Test.');
nBC = numel(bc_rows);

% ===== Figure Layout =====
figure('Color','w','Name','MBP/BC/WV + Speed Overlay');
tlo = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

% ===== (1) MBP, BC, WV Overlay =====
ax1 = nexttile; hold on; grid on;

% MBP base
if isfield(Test(jMBP),'Time') && isfield(Test(jMBP),'Pressure_filter')
    plot(Test(jMBP).Time, Test(jMBP).Pressure_filter, '-', ...
        'Color', colMBPbg, 'LineWidth', 1.0);
end

% MBP overlays
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'MBP_Time') || ~isfield(TestBrake(k),'MBP_Pressure'), continue; end
    c = colMBPok;
    if isfield(TestBrake(k),'SV_Error') && TestBrake(k).SV_Error, c = colErr; end
    plot(TestBrake(k).MBP_Time, TestBrake(k).MBP_Pressure, '-', ...
        'Color', c, 'LineWidth', 1.6);
end

% BC overlays
for r = 1:nBC
    jr = bc_rows(r);
    if isfield(Test(jr),'Time') && isfield(Test(jr),'Pressure_filter')
        plot(Test(jr).Time, Test(jr).Pressure_filter, '-', ...
            'Color', colBCbg, 'LineWidth', 0.9);
    end
end
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'BC'), continue; end
    for r = 1:numel(TestBrake(k).BC)
        B = TestBrake(k).BC(r);
        if ~isfield(B,'Time') || ~isfield(B,'Pressure'), continue; end
        c = bcMap(mod(r-1,size(bcMap,1))+1,:);
        if isfield(B,'SensorError') && B.SensorError, c = colErr; end
        plot(B.Time, B.Pressure, '-', 'Color', c, 'LineWidth', 1.5);
    end
end

% WV overlays (dashed)
for k = 1:numel(TestBrake)
    if ~isfield(TestBrake(k),'WV'), continue; end
    for r = 1:numel(TestBrake(k).WV)
        W = TestBrake(k).WV(r);
        if ~isfield(W,'Time') || ~isfield(W,'Pressure'), continue; end
        c = wvMap(mod(r-1,size(wvMap,1))+1,:);
        if isfield(W,'WV_SensorError') && W.WV_SensorError, c = colErr; end
        plot(W.Time, W.Pressure, '--', 'Color', c, 'LineWidth', 1.2);
    end
end

ylabel('Pressure [bar]');
title('MBP + BC + WV Overlay');

% ===== (2) Speed + Speed_RPM Overlay =====
ax2 = nexttile; hold on; grid on;

% Pre-allocate legend handles (may stay empty if data is missing)
hSpeed    = [];
hSpeedRPM = [];
hGps      = [];
hGpsRpm   = [];

t = Test(jMBP).Time_GPS;

% --- Main Speed traces from Test(jMBP) ---
if isfield(Test(jMBP),'Speed')
    hSpeed = plot(t, Test(jMBP).Speed, '-', 'LineWidth', 1.4, ...
                  'DisplayName','Speed');
end

if isfield(Test(jMBP),'Speed_RPM')
    hSpeedRPM = plot(t, Test(jMBP).Speed_RPM, '--', 'LineWidth', 1.4, ...
                     'DisplayName','Speed\_RPM');
end

% --- Overlay GPS-based speeds from TestBrake ---
for k = 1:numel(TestBrake)

    % GPS_Speed
    if isfield(TestBrake(k),'GPS_Speed') && isfield(TestBrake(k),'GPS_Time_shifted') ...
            && ~isempty(TestBrake(k).GPS_Speed) && ~isempty(TestBrake(k).GPS_Time_shifted)

        if isempty(hGps)
            % First GPS_Speed -> use in legend
            hGps = plot(TestBrake(k).GPS_Time_shifted, TestBrake(k).GPS_Speed, 'o', ...
                        'Color', [0.00 0.60 0.00], ...
                        'DisplayName','GPS\_Speed', ...
                        'MarkerSize', 4, 'LineWidth', 1.2);
        else
            % Additional points -> do NOT appear in legend
            plot(TestBrake(k).GPS_Time_shifted, TestBrake(k).GPS_Speed, 'o', ...
                 'Color', [0.00 0.60 0.00], ...
                 'HandleVisibility','off', ...   % <--- hide from legend
                 'MarkerSize', 4, 'LineWidth', 1.2);
        end
    end

    % GPS_Speed_RPM
    if isfield(TestBrake(k),'GPS_Speed_RPM') && isfield(TestBrake(k),'GPS_Time_shifted') ...
            && ~isempty(TestBrake(k).GPS_Speed_RPM) && ~isempty(TestBrake(k).GPS_Time_shifted)

        if isempty(hGpsRpm)
            % First GPS_Speed_RPM -> use in legend
            hGpsRpm = plot(TestBrake(k).GPS_Time_shifted, TestBrake(k).GPS_Speed_RPM, 's', ...
                           'Color', [0.49 0.18 0.56], ...
                           'DisplayName','GPS\_Speed\_RPM', ...
                           'MarkerSize', 4, 'LineWidth', 1.2);
        else
            % Additional points -> hidden from legend
            plot(TestBrake(k).GPS_Time_shifted, TestBrake(k).GPS_Speed_RPM, 's', ...
                 'Color', [0.49 0.18 0.56], ...
                 'HandleVisibility','off', ...   % <--- hide from legend
                 'MarkerSize', 4, 'LineWidth', 1.2);
        end
    end
end

xlabel('Time');
ylabel('Speed');
title('Speed + Speed\_RPM + GPS Overlay');

% ---- Build legend only from the available handles ----
legHandles = [];
legNames   = {};

if ~isempty(hSpeed)
    legHandles(end+1) = hSpeed;
    legNames{end+1}   = 'Speed';
end
if ~isempty(hSpeedRPM)
    legHandles(end+1) = hSpeedRPM;
    legNames{end+1}   = 'Speed\_RPM';
end
if ~isempty(hGps)
    legHandles(end+1) = hGps;
    legNames{end+1}   = 'GPS\_Speed';
end
if ~isempty(hGpsRpm)
    legHandles(end+1) = hGpsRpm;
    legNames{end+1}   = 'GPS\_Speed\_RPM';
end

if ~isempty(legHandles)
    legend(ax2, legHandles, legNames, 'Location','best');
end


% ===== Link x-axes and Zoom Span =====
linkaxes([ax1, ax2],'x');

%%
tStart = []; tEnd = [];
for k = 1:numel(TestBrake)
    if isfield(TestBrake(k),'MBP_Time') && ~isempty(TestBrake(k).MBP_Time)
        if isempty(tStart), tStart = TestBrake(k).MBP_Time(1); end
        tEnd = TestBrake(k).MBP_Time(end);
    end
end
if ~isempty(tStart) && ~isempty(tEnd)
    xlim([tStart tEnd]);
end

%% ======= PLOT: 1× MBP (from one cell) + BC from ALL cells (same phase) =======
phaseId = refPhase; if isnan(phaseId), phaseId = 18; end
phaseId = 47;
mbpCellIdx = 1;
allSets    = TBsets_out;

% --- Colors & markers ---
col_mbp  = [0.00 0.45 0.74];   % MBP (PIPE) line
col_bc   = [0.00 0.00 0.00];   % BC (CYL) line
col_full = [0.80 0.80 0.80];   % base/secondary line color
col_buil = [0.00 0.45 0.74];   % buildup markers
col_hold = [0.20 0.60 0.20];   % holding markers
col_rel  = [0.85 0.33 0.10];   % release markers
msize    = 14;

nCells = numel(allSets);
if nCells == 0, error('TBsets_out is empty.'); end
if mbpCellIdx < 1 || mbpCellIdx > nCells, error('mbpCellIdx out of range.'); end

figure('Color','w','Name',sprintf('Phase %d: MBP (cell %d) + BC from all cells', phaseId, mbpCellIdx));
tiledlayout(nCells + 1, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

% ---------------- Row 1: MBP (PIPE) from mbpCellIdx ----------------
nexttile; hold on; grid on;
titleTxt = sprintf('MBP — Cell %d — Phase %d', mbpCellIdx, phaseId);

Smbp = [];
if ~isempty(allSets{mbpCellIdx}) && numel(allSets{mbpCellIdx}) >= phaseId && isstruct(allSets{mbpCellIdx}(phaseId))
    Smbp = allSets{mbpCellIdx}(phaseId);
end

if ~isempty(Smbp) && isfield(Smbp,'MBP_Time') && isfield(Smbp,'MBP_Pressure') && ...
        ~isempty(Smbp.MBP_Time) && ~isempty(Smbp.MBP_Pressure)

    t = Smbp.MBP_Time; p = Smbp.MBP_Pressure;
    plot(t, p, '-', 'Color', col_mbp, 'LineWidth', 1.4, 'DisplayName', 'MBP');

    % Subphase times (PIPE)
    TB = []; TH = []; TR = [];
    if isfield(Smbp,'Buildup_time_pipe')  && ~isempty(Smbp.Buildup_time_pipe),  TB = Smbp.Buildup_time_pipe(:);  end
    if isfield(Smbp,'Holding_time_pipe')  && ~isempty(Smbp.Holding_time_pipe),  TH = Smbp.Holding_time_pipe(:);  end
    if isfield(Smbp,'Release_time_pipe')  && ~isempty(Smbp.Release_time_pipe),  TR = Smbp.Release_time_pipe(:);  end

    % Vertical markers (first of each, last of release)
    if ~isempty(TB) && isdatetime(TB(1)) && ~isnat(TB(1)), xline(TB(1),'--','Color',col_buil,'Label','Buildup'); end
    if ~isempty(TH) && isdatetime(TH(1)) && ~isnat(TH(1)), xline(TH(1),'--','Color',col_hold,'Label','End buildup'); end
    if ~isempty(TR) && isdatetime(TR(1)) && ~isnat(TR(1)), xline(TR(1),'--','Color',col_rel,'Label','Release'); end
    if ~isempty(TR) && isdatetime(TR(end)) && ~isnat(TR(end)), xline(TR(end),':','Color',col_rel,'Label','End Release'); end

    % Highlight subphase points by nearest-index sampling
    if ~isempty(TB)
        idxB = zeros(numel(TB),1);
        for q = 1:numel(TB), [~,idxB(q)] = min(abs(t - TB(q))); end
        idxB = unique(idxB(~isnan(idxB)));
        if ~isempty(idxB)
            scatter(t(idxB), p(idxB), msize, 'filled', 'MarkerFaceColor', col_buil, ...
                'MarkerEdgeColor','none', 'DisplayName', 'Buildup');
        end
    end
    if ~isempty(TH)
        idxH = zeros(numel(TH),1);
        for q = 1:numel(TH), [~,idxH(q)] = min(abs(t - TH(q))); end
        idxH = unique(idxH(~isnan(idxH)));
        if ~isempty(idxH)
            scatter(t(idxH), p(idxH), msize, 'filled', 'MarkerFaceColor', col_hold, ...
                'MarkerEdgeColor','none', 'DisplayName', 'Holding');
        end
    end
    if ~isempty(TR)
        idxR = zeros(numel(TR),1);
        for q = 1:numel(TR), [~,idxR(q)] = min(abs(t - TR(q))); end
        idxR = unique(idxR(~isnan(idxR)));
        if ~isempty(idxR)
            scatter(t(idxR), p(idxR), msize, 'filled', 'MarkerFaceColor', col_rel, ...
                'MarkerEdgeColor','none', 'DisplayName', 'Release');
        end
    end

    % IDs in the title if available
    if isfield(Smbp,'MBP_ID') && ~isempty(Smbp.MBP_ID)
        titleTxt = sprintf('%s | MBP:%s', titleTxt, string(Smbp.MBP_ID));
    end
else
    plot(nan, nan); % keep axes
    titleTxt = sprintf('%s — no MBP data', titleTxt);
end

ylabel('Pressure [bar]');
xlabel('Time');
title(titleTxt);
hL = legend('show','Location','best');
if isempty(hL), legend('off'); end
% ---------------- Rows 2..N+1: BC (CYL) from each cell ----------------
for c = 1:nCells
    nexttile; hold on; grid on;
    titleTxt = sprintf('BC — Cell %d — Phase %d', c, phaseId);

    Sc = [];
    if ~isempty(allSets{c}) && numel(allSets{c}) >= phaseId && isstruct(allSets{c}(phaseId))
        Sc = allSets{c}(phaseId);
    end

    if ~isempty(Sc) && isfield(Sc,'BC_Time') && isfield(Sc,'BC_Pressure') && ...
            ~isempty(Sc.BC_Time) && ~isempty(Sc.BC_Pressure)

        % --------- MAKE BC TIME DATETIME (CONSISTENT WITH MBP) ----------
        % Use MBP start as reference epoch for relative seconds/durations
        t0 = [];
        if exist('Smbp','var') && isstruct(Smbp) && isfield(Smbp,'MBP_Time') && ~isempty(Smbp.MBP_Time)
            t0 = Smbp.MBP_Time(1);
        end

        t2_dt = Sc.BC_Time; % default

        if isdatetime(Sc.BC_Time)
            % already datetime : keep
            t2_dt = Sc.BC_Time;

        elseif isduration(Sc.BC_Time)
            % duration : add to MBP epoch if available
            if ~isempty(t0) && isdatetime(t0)
                t2_dt = t0 + Sc.BC_Time;
            else
                % fallback: convert to datetime from seconds since 0 (won't be comparable)
                t2_dt = datetime(seconds(Sc.BC_Time));
            end

        elseif isnumeric(Sc.BC_Time)
            % numeric : decide POSIX vs relative seconds
            t2 = Sc.BC_Time(:);
            if any(isnan(t2))
                % keep NaNs; convert valid entries
                t2(isnan(t2)) = 0;
            end
            looksPosix = max(t2) >= 1e7;  % heuristic threshold

            if looksPosix
                % POSIX seconds since 1970
                t2_dt = datetime(Sc.BC_Time, 'ConvertFrom','posixtime');  % no TZ set
            else
                % relative seconds from MBP start
                if ~isempty(t0) && isdatetime(t0)
                    t2_dt = t0 + seconds(Sc.BC_Time);
                else
                    % last resort: treat as POSIX anyway (prevents mixed types)
                    t2_dt = datetime(Sc.BC_Time, 'ConvertFrom','posixtime');
                end
            end
        else
            % unknown type : coerce via datetime (best-effort)
            try
                t2_dt = datetime(Sc.BC_Time);
            catch
                % ensure we still have a datetime vector (NaT baseline)
                t2_dt = NaT(size(Sc.BC_Time));
            end
        end
        % ----------------------------------------------------------------

        p2 = Sc.BC_Pressure;
        plot(t2_dt, p2, '-', 'Color', col_bc, 'LineWidth', 1.2, 'DisplayName', 'BC');

        % Subphase times (CYL) : also convert to datetime consistently
        TB2 = []; TH2 = []; TR2 = [];
        if isfield(Sc,'Buildup_time_cyl') && ~isempty(Sc.Buildup_time_cyl), TB2 = Sc.Buildup_time_cyl(:); end
        if isfield(Sc,'Holding_time_cyl') && ~isempty(Sc.Holding_time_cyl), TH2 = Sc.Holding_time_cyl(:); end
        if isfield(Sc,'Release_time_cyl') && ~isempty(Sc.Release_time_cyl), TR2 = Sc.Release_time_cyl(:); end

        % Helper inline converter to datetime using same rules as above
        % (inlined to avoid separate functions)
        if ~isempty(TB2) && ~isdatetime(TB2)
            if isduration(TB2)
                if ~isempty(t0), TB2 = t0 + TB2; else, TB2 = datetime(seconds(TB2)); end
            elseif isnumeric(TB2)
                if max(TB2) >= 1e7
                    TB2 = datetime(TB2,'ConvertFrom','posixtime');
                else
                    if ~isempty(t0), TB2 = t0 + seconds(TB2); else, TB2 = datetime(TB2,'ConvertFrom','posixtime'); end
                end
            else
                try TB2 = datetime(TB2); catch, TB2 = NaT(size(TB2)); end
            end
        end
        if ~isempty(TH2) && ~isdatetime(TH2)
            if isduration(TH2)
                if ~isempty(t0), TH2 = t0 + TH2; else, TH2 = datetime(seconds(TH2)); end
            elseif isnumeric(TH2)
                if max(TH2) >= 1e7
                    TH2 = datetime(TH2,'ConvertFrom','posixtime');
                else
                    if ~isempty(t0), TH2 = t0 + seconds(TH2); else, TH2 = datetime(TH2,'ConvertFrom','posixtime'); end
                end
            else
                try TH2 = datetime(TH2); catch, TH2 = NaT(size(TH2)); end
            end
        end
        if ~isempty(TR2) && ~isdatetime(TR2)
            if isduration(TR2)
                if ~isempty(t0), TR2 = t0 + TR2; else, TR2 = datetime(seconds(TR2)); end
            elseif isnumeric(TR2)
                if max(TR2) >= 1e7
                    TR2 = datetime(TR2,'ConvertFrom','posixtime');
                else
                    if ~isempty(t0), TR2 = t0 + seconds(TR2); else, TR2 = datetime(TR2,'ConvertFrom','posixtime'); end
                end
            else
                try TR2 = datetime(TR2); catch, TR2 = NaT(size(TR2)); end
            end
        end

        % Vertical markers (first of each, last of release)
        if ~isempty(TB2) && isdatetime(TB2(1)) && ~isnat(TB2(1)), xline(TB2(1),'--','Color',col_buil); end
        if ~isempty(TH2) && isdatetime(TH2(1)) && ~isnat(TH2(1)), xline(TH2(1),'--','Color',col_hold); end
        if ~isempty(TR2) && isdatetime(TR2(1)) && ~isnat(TR2(1)), xline(TR2(1),'--','Color',col_rel); end
        if ~isempty(TR2) && isdatetime(TR2(end)) && ~isnat(TR2(end)), xline(TR2(end),':','Color',col_rel); end

        % Highlight subphase points (hidden from legend)
        if ~isempty(TB2)
            idxB2 = zeros(numel(TB2),1);
            for q = 1:numel(TB2), [~,idxB2(q)] = min(abs(t2_dt - TB2(q))); end
            idxB2 = unique(idxB2(~isnan(idxB2)));
            if ~isempty(idxB2)
                scatter(t2_dt(idxB2), p2(idxB2), msize, 'filled', 'MarkerFaceColor', col_buil, ...
                    'MarkerEdgeColor','none', 'HandleVisibility','off');
            end
        end
        if ~isempty(TH2)
            idxH2 = zeros(numel(TH2),1);
            for q = 1:numel(TH2), [~,idxH2(q)] = min(abs(t2_dt - TH2(q))); end
            idxH2 = unique(idxH2(~isnan(idxH2)));
            if ~isempty(idxH2)
                scatter(t2_dt(idxH2), p2(idxH2), msize, 'filled', 'MarkerFaceColor', col_hold, ...
                    'MarkerEdgeColor','none', 'HandleVisibility','off');
            end
        end
        if ~isempty(TR2)
            idxR2 = zeros(numel(TR2),1);
            for q = 1:numel(TR2), [~,idxR2(q)] = min(abs(t2_dt - TR2(q))); end
            idxR2 = unique(idxR2(~isnan(idxR2)));
            if ~isempty(idxR2)
                scatter(t2_dt(idxR2), p2(idxR2), msize, 'filled', 'MarkerFaceColor', col_rel, ...
                    'MarkerEdgeColor','none', 'HandleVisibility','off');
            end
        end

        % IDs in the title if available
        if isfield(Sc,'BC_ID') && ~isempty(Sc.BC_ID)
            titleTxt = sprintf('%s | BC:%s', titleTxt, string(Sc.BC_ID));
        end

        % >>> Force BC y-axis to start at 0 <<<
        yl = ylim;
        if isfinite(yl(2)) && yl(2) > 0
            ylim([0, yl(2)]);
        else
            ylim([0, 1]);
        end

    else
        plot(nan, nan); % keep axes visible
        titleTxt = sprintf('%s — no BC data', titleTxt);
        ylim([0, 1]);   % still start at 0 for empty plots
    end

    ylabel('Pressure [bar]');
    xlabel('Time');
    legend('show','Location','best');
    title(titleTxt);
end

% --- Link all time axes (now all datetime) ---
ax = findall(gcf, 'type', 'axes');
ax = ax(isgraphics(ax));
ax = ax(arrayfun(@(a) ~strcmp(get(a,'Tag'),'legend'), ax));

if numel(ax) >= 2
    try
        linkaxes(ax, 'x');
    catch ME
        warning(ME.identifier, 'linkaxes failed: %s', ME.message);
    end
else
    warning('plot:linkaxesSkipped', 'Skipping linkaxes: found only %d valid axes.', numel(ax));
end


%% plot_TBsets_phases
% hfig_power = plot_TBsets_phases(TBsets_out, 'Total_power_efficiency');
%% hFig_flags = plot_TBsets_phases_flags(TBsets_out);
% hFig_curv = plot_TBsets_phases(TBsets_out, 'First_phase_mean_curvature');
plot_TBsets_phases(TestBrakes_sorted, 'Total_power_efficiency');

% %% Box Plots
% % --- Example: assuming your data are stored in a table called T ---
% % Columns: T.Total_power_efficiency, T.Energy_ratio, T.TotalPowerDelay, T.BuildupEndPressureDelay,
% %          T.ReleaseStartPressureDelay, T.Non_Standard_Braking
% T = TestBrakes_table;
% % T = PerFolder_Master;
% vars = {'Total_power_efficiency', 'Total_EN_eff', 'Total_power_delay','Buildup_end_pressure_delay','Release_start_pressure_delay'};
% 
% figure('Name','Comparison of Key Metrics Consecutive Braking','Color','w');
% tiledlayout(2,3, 'Padding', 'compact', 'TileSpacing', 'compact');
% 
% for i = 1:numel(vars)
%     nexttile;
%     varName = vars{i};
%     if ismember(varName, T.Properties.VariableNames)
%         % Extract variable and group
%         x = T.Consecutive_braking_pipe;
%         y = T.(varName);
% 
%         % --- Boxplot ---
%         boxchart(categorical(x), y, 'BoxFaceColor',[0.2 0.6 0.8]);
%         xlabel('Braking Case (0 = Standard, 1 = ConsecutiveBraking)');
%         ylabel(varName, 'Interpreter','none');
%         title(strrep(varName,'_',' '));
% 
%     else
%         text(0.5,0.5,['Missing: ',varName],'HorizontalAlignment','center');
%     end
% end
% 
% % Adjust layout
% sgtitle('Comparison by Consecutive Braking');
% vars = {'Total_power_efficiency', 'Total_EN_eff', 'Total_power_delay','Buildup_end_pressure_delay','Release_start_pressure_delay'};
% 
% figure('Name','Standard Braking Metric','Color','w');
% tiledlayout(2,3, 'Padding', 'compact', 'TileSpacing', 'compact');
% 
% for i = 1:numel(vars)
%     nexttile;
%     varName = vars{i};
%     if ismember(varName, T.Properties.VariableNames)
%         % Extract variable and group
%         x = T.Non_Standard_Braking;
%         y = T.(varName);
% 
%         % --- Boxplot ---
%         boxchart(categorical(x), y, 'BoxFaceColor',[0.2 0.6 0.8]);
%         xlabel('Braking Case (0 = Standard, 1 = NonStandard)');
%         ylabel(varName, 'Interpreter','none');
%         title(strrep(varName,'_',' '));
% 
%     else
%         text(0.5,0.5,['Missing: ',varName],'HorizontalAlignment','center');
%     end
% end
% % Adjust layout
% sgtitle('Comparison of Key Metrics by Braking Action');
% 
% % Assume T is your table and T.WV_MeanPressure exists
% pressure = T.WV_MeanPressure;
% 
% % Remove NaNs / missing
% validPres = pressure(~isnan(pressure));
% 
% % Choose number of bins (for example 3 bins)
% nBins = 3;
% 
% % Compute edges automatically (equal‑width)
% minP = min(validPres);
% maxP = max(validPres);
% 
% % To ensure the max value is included, you might extend the upper edge a little
% edges = linspace(minP, maxP, nBins+1);
% 
% % Define labels
% binLabels = arrayfun(@(k) sprintf('%.2f‑%.2f', edges(k), edges(k+1)), 1:nBins, 'uni',false);
% 
% % Now discretize
% pressureBins = discretize(pressure, edges, 'categorical', binLabels);
% 
% % Then your original code:
% brakeCat = categorical(T.Non_Standard_Braking, [0 1], {'Standard','NonStandard Braking'});
% 
% figure('Name','Comparison of Key Metrics by Braking Type','Color','w');
% tiledlayout(2,3,'Padding','compact','TileSpacing','compact');
% 
% for i = 1:numel(vars)
%     nexttile;
%     varName = vars{i};
%     if ismember(varName, T.Properties.VariableNames)
%         y = T.(varName);
% 
%         % Filter
%         valid = ~isnan(y) & ~ismissing(pressureBins) & ~ismissing(brakeCat);
%         y = y(valid);
%         x = brakeCat(valid);
%         g = pressureBins(valid);
% 
%         % Plot
%         boxchart(x, y, 'GroupByColor', g);
%         xlabel('Braking Type');
%         ylabel(varName, 'Interpreter','none');
%         title(strrep(varName, '_', ' '));
%         legend(categories(g), 'Location','bestoutside');
%         grid on;
%     else
%         text(0.5,0.5, ['Missing: ', varName], 'HorizontalAlignment','center');
%     end
% end
% 
% sgtitle('Metric Comparison by Braking Type and Mean Pressure Bins');
% 
% %% Run analysis for Total_Power_eff
% Tfinal = TestBrakes_table;
% T = Tfinal;
% 
% TB_filteredtable = T(T.Non_Standard_Braking == 0, :);
% 
% % --- Extract & FILTER Total_Power_eff: keep only 0 ≤ x ≤ 100 ---
% x = TB_filteredtable.Total_power_efficiency;
% valid = isfinite(x) & x >= 0 & x <= 100;       % <-- this is the key change
% Total_Power_eff_data = x(valid);
% 
% % --- Fit Normal and compute 95% threshold ---
% mu    = mean(Total_Power_eff_data);
% sigma = std(Total_Power_eff_data);
% Total_Power_eff_95pct_threshold = mu - 1.645 * sigma;     % one-sided 95% lower tail
% Total_Power_eff_empirical_95pct = prctile(Total_Power_eff_data, 95);
% 
% [h_ks,p_ks] = kstest((Total_Power_eff_data - mu)/sigma);
% fprintf('KS test vs Normal: H=%d, p=%.4g\n', h_ks, p_ks);
% 
% Total_Power_eff_threshold = Total_Power_eff_95pct_threshold;
% 
% fp_rate_est = mean(Total_Power_eff_data < Total_Power_eff_threshold);
% fprintf('Estimated false-positive rate on baseline: %.2f%%\n', 100 * fp_rate_est);
% 
% % --- Apply to new data (flag suspected leakage) ---
% TB_filteredtable.LeakageFlag = TB_filteredtable.Total_power_efficiency < Total_Power_eff_threshold;
% 
% %% ================== STANDARD vs NONSTANDARD BRAKING CONFIG ==================
% % BoxPlot
% 
% vars = {'Total_power_efficiency', 'Total_power_delay', ...
%     'Buildup_end_pressure_delay', 'Release_start_pressure_delay'};
% 
% % Pressure binning
% nBins = 3;                 % number of WV_MeanPressure bins
% binMode = 'quantile';      % 'equalwidth' or 'quantile'
% 
% % X-axis group order (fixed 4 combos)
% xCats = ["Standard | NonConsecutive", ...
%     "Standard | Consecutive", ...
%     "NonStandard | NonConsecutive", ...
%     "NonStandard | Consecutive"];
% 
% % ================== PREP: PRESSURE BINS (fixed [<2, 2–3, >3]) ==================
% pressure = T.WV_MeanPressure;
% 
% edges     = [-inf, 2, 3, inf];                % three bins: (-inf,2], (2,3], (3,inf)
% binLabels = ["<2", "2–3", ">3"];
% 
% % Discretize with right-inclusive edges so 2→first bin, 3→second bin
% pressureBins = discretize(pressure, edges, 'IncludedEdge','right');
% 
% % Map to categorical with fixed category order for legend/consistency
% g = categorical(pressureBins, 1:3, cellstr(binLabels));
% g = reordercats(g, cellstr(binLabels));
% 
% % ================== PREP: X-AXIS GROUPS ==================
% brakeCat = categorical(T.Non_Standard_Braking, [0 1], {'Standard','NonStandard'});
% pipeCat  = categorical(T.Consecutive_braking_pipe, [0 1], {'NonConsecutive','Consecutive'});
% 
% groupX = categorical(strcat(string(brakeCat), " | ", string(pipeCat)));
% groupX = renamecats(groupX, categories(groupX), categories(groupX)); % no-op; ensures valid
% % Force full set of 4 groups in fixed order
% groupX = categorical(string(groupX), xCats, xCats, 'Ordinal', true);
% 
% % ================== PLOTTING ==================
% figure('Name','Metrics by Braking Type','Color','w');
% tiledlayout(2,2,'Padding','compact','TileSpacing','compact');
% 
% % Keep consistent colors across subplots
% binLabels = ["<2","2–3",">3"];
% co = lines(numel(binLabels));  
% 
% for i = 1:numel(vars)
%     nexttile;
%     varName = vars{i};
%     if ~ismember(varName, T.Properties.VariableNames)
%         text(0.5,0.5,['Missing: ' varName],'HorizontalAlignment','center'); axis off;
%         continue;
%     end
% 
%     y = T.(varName);
%     if strcmp(varName, 'Total_power_efficiency')
%         keep = isfinite(y) & y >= 0 & y <= 100;
%         y(~keep) = NaN;   % drop out-of-range points
%     end
% 
%     if strcmp(varName, 'Total_power_delay')
%         keep = isfinite(y) & y >= -100 & y <= 100;
%         y(~keep) = NaN;   % drop out-of-range points
%     end
% 
%     x = groupX;
%     c = g;
% 
%     % Valid rows: y finite, x not missing, c not missing
%     valid = ~isnan(y) & isfinite(y) & ~ismissing(x) & ~ismissing(c);
%     y = y(valid); x = x(valid); c = c(valid);
% 
%     if isempty(y)
%         text(0.5,0.5,['No data for ' varName],'HorizontalAlignment','center'); axis off;
%         continue;
%     end
% 
%     h = boxchart(x, y, 'GroupByColor', c);
% 
%     % Only the bins that actually appear in this tile:
%     catsPresent = categories(removecats(c));  % e.g., {"<2","2–3"} if ">3" absent
% 
%     % Color each drawn box using the full palette index of its label
%     for ii = 1:numel(h)                       % numel(h) == numel(catsPresent)
%         lab = catsPresent{ii};
%         idx = find(strcmp(lab, cellstr(binLabels)), 1);
%         if isempty(idx), idx = 1; end         % safety
%         h(ii).BoxFaceColor = co(idx,:);
%         h(ii).MarkerColor  = co(idx,:);
%     end
% 
%     % Legend shows only present bins
%     lg = legend(catsPresent, 'Location','northeastoutside');
%     lg.Title.String = 'WV MeanPressure bins';
% 
% end
% 
% sgtitle('Metric Comparison by Braking Type, Consecutive Pipe, and WV MeanPressure Bins');
% 
% % Optional: tighten x-limits to existing categories
% ax = findall(gcf,'Type','axes');
% for k = 1:numel(ax)
%     if isa(ax(k), 'matlab.graphics.axis.Axes')
%         ax(k).XLimMode = 'auto';
%     end
% end
% 
% %%
% % ================== STANDARD BRAKING: BOXCHART + MEDIANS ==================
% T = Tfinal(Tfinal.Non_Standard_Braking == 0, :);
% % Count NaN values
% numNaN = sum(isnan(T.WV_MeanPressure));
% 
% % Count non-NaN values
% numValues = sum(~isnan(T.WV_MeanPressure));
% 
% % Display results
% fprintf('Number of NaN values: %d\n', numNaN);
% fprintf('Number of non-NaN values: %d\n', numValues);
% 
% %%
% vars = {'Total_power_efficiency', 'Total_power_delay', ...
%         'Buildup_end_pressure_delay', 'Release_start_pressure_delay'};
% 
% % --- WV_MeanPressure bins [<2, 2–3, >3] ---
% edges     = [-inf, 2, 3, inf];
% binLabels = ["<2 bar","2–3 bar",">3 bar"];
% pressure  = T.WV_MeanPressure;
% binIdx    = discretize(pressure, edges, 'IncludedEdge','right');
% g         = categorical(binIdx, 1:3, cellstr(binLabels));
% g         = reordercats(g, cellstr(binLabels));
% 
% % Color palette (fixed 3 bins)
% co = lines(numel(binLabels));
% 
% % --- Figure ---
% figure('Name','Standard braking: metrics vs WV bins','Color','w');
% tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
% 
% for i = 1:numel(vars)
%     varName = vars{i};
%     if ~ismember(varName, T.Properties.VariableNames)
%         continue;
%     end
% 
%     y = T.(varName);
% 
%     % Clean ranges (like before)
%     if strcmp(varName, 'Total_power_efficiency')
%         keep = isfinite(y) & y >= 0 & y <= 100;
%     elseif strcmp(varName, 'Total_power_delay')
%         keep = isfinite(y) & y >= -100 & y <= 100;
%     else
%         keep = isfinite(y);
%     end
% 
%     y(~keep) = NaN;
% 
%     valid = isfinite(y) & ~ismissing(g);
%     yv = y(valid);
%     gv = g(valid);
% 
%     nexttile;
%     h = boxchart(gv, yv);
% 
%     % Match colors to bins
%     catsPresent = categories(removecats(gv));
%     for ii = 1:numel(h)
%         lab = catsPresent{ii};
%         idx = find(strcmp(lab, cellstr(binLabels)), 1);
%         if isempty(idx), idx = 1; end
%         h(ii).BoxFaceColor = co(idx,:);
%         h(ii).MarkerColor  = co(idx,:);
%     end
% 
%     title(strrep(varName,'_',' '));
%     xlabel('WV Mean Pressure [bar]')
%     ylabel('Value');
%     grid on;
% 
%     % --- Compute and print median per bin ---
%     fprintf('\n%s — Median by WV_MeanPressure bin:\n', varName);
%     med = groupsummary(table(yv,gv), 'gv', 'median', 'yv');
%     disp(med);
% end
% 
% sgtitle('Standard braking — WV MeanPressure bins');
% 
% % %% === Locate outliers for each variable (with source row indices) ===
% % OutlierSummary = table( ...
% %     'Size',[0 5], ...
% %     'VariableTypes', {'double','string','string','string','double'}, ...
% %     'VariableNames', {'SourceIndex','Variable','BrakingPipeGroup','WV_Bin','Value'});
% % for i = 1:numel(vars)
% %     varName = vars{i};
% %     if ~ismember(varName, T.Properties.VariableNames)
% %         continue;
% %     end
% % 
% %     y = T.(varName);
% % 
% %     % --- Clean the same way as your plotting logic ---
% %     if strcmp(varName, 'Total_power_efficiency')
% %         keep = isfinite(y) & y >= 0 & y <= 100;
% %         y(~keep) = NaN;
% %     elseif strcmp(varName, 'Total_power_delay')
% %         keep = isfinite(y) & y >= -100 & y <= 100;
% %         y(~keep) = NaN;
% %     end
% % 
% %     x = groupX;   % braking/pipe categorical
% %     c = g;        % WV pressure bin categorical
% % 
% %     % Keep only valid rows
% %     valid = ~isnan(y) & isfinite(y) & ~ismissing(x) & ~ismissing(c);
% %     y = y(valid);
% %     x = x(valid);
% %     c = c(valid);
% %     srcIdx = find(valid);   % <--- keeps original row indices in T
% % 
% %     if isempty(y)
% %         continue;
% %     end
% % 
% %     % --- Detect outliers per (x,c) combination ---
% %     [G, groupNames] = findgroups(x, c);
% %     outMask = false(size(y));
% % 
% %     for gidx = 1:max(G)
% %         yg = y(G == gidx);
% %         if numel(yg) < 4
% %             continue; % too few to compute quartiles
% %         end
% %         Q1 = quantile(yg, 0.25);
% %         Q3 = quantile(yg, 0.75);
% %         IQRv = Q3 - Q1;
% %         lowerFence = Q1 - 1.5*IQRv;
% %         upperFence = Q3 + 1.5*IQRv;
% %         outMask(G == gidx) = yg < lowerFence | yg > upperFence;
% %     end
% % 
% %     % --- Store results ---
% %     % Inside your loop, when adding rows:
% %     if any(outMask)
% %         idx  = srcIdx(outMask);          % indices in T
% %         xx   = x(outMask);               % categorical -> convert to string
% %         cc   = c(outMask);               % categorical -> convert to string
% %         vals = y(outMask);
% % 
% %         % Force columns
% %         idx  = idx(:);
% %         vals = vals(:);
% % 
% %         % Build one table in a single call (consistent row counts)
% %         tbl = table( ...
% %             idx, ...
% %             repmat(string(varName), numel(idx), 1), ...
% %             string(xx(:)), ...   % <- convert to string to avoid ordinal cat mismatch
% %             string(cc(:)), ...   % <- convert to string to avoid ordinal cat mismatch
% %             vals, ...
% %             'VariableNames', {'SourceIndex','Variable','BrakingPipeGroup','WV_Bin','Value'});
% % 
% %         OutlierSummary = [OutlierSummary; tbl]; %#ok<AGROW>
% %     end
% % end
% % OutlierSummary = OutlierSummary(OutlierSummary.Value<2,:);
% % % Optionally, save it to a file for inspection
% % % writetable(OutlierSummary, 'OutlierSummary.csv');
% % % --- 1) Add a 1-based row index to Tfinal (key for the join)
% % Tfinal_indexed = addvars(Tfinal, (1:height(Tfinal))', ...
% %     'NewVariableNames','SourceIndex', 'Before', 1);
% % 
% % % --- 2) Keep only valid, in-range indices in your OutlierSummary
% % isValid = isfinite(OutlierSummary.SourceIndex) & ...
% %           OutlierSummary.SourceIndex >= 1 & ...
% %           OutlierSummary.SourceIndex <= height(Tfinal_indexed);
% % OutlierSummary = OutlierSummary(isValid, :);
% % 
% % % If SourceIndex might not be integer-typed, make sure it is:
% % OutlierSummary.SourceIndex = floor(double(OutlierSummary.SourceIndex));
% % 
% % % (Optional) keep only lower-end outliers as you already do
% % OutlierSummary = OutlierSummary(OutlierSummary.Value < 2, :);
% % 
% % % --- 3) Join: replicate Tfinal rows for each matching SourceIndex
% % % This preserves all rows in OutlierSummary and attaches the matching row from Tfinal.
% % OutlierSummaryFull = innerjoin(OutlierSummary, Tfinal_indexed, 'Keys', 'SourceIndex');
% % 
% % % OutlierSummaryFull now contains:
% % % [SourceIndex, Variable, BrakingPipeGroup, WV_Bin, Value] from OutlierSummary
% % % + all variables from the matching row(s) of Tfinal.
% % % MATLAB will auto-disambiguate duplicate names by suffixing, if any.
% % 
% %% GPS Speeeeeddd
% idx = arrayfun(@(s) all(s.SV_Error == 0), TBsets_out_concat_struct);
% TB_gps = TBsets_out_concat_struct(idx);
% 
% figure('Color','w'); hold on; grid on;
% xlabel('Time since start (s)');
% ylabel('Speed');
% title('GPS Speed vs RPM-based Speed for All Braking Actions');
% colororder(lines);
% 
% for k = 1:numel(TB_gps)
% 
%     t_gps = TB_gps(k).GPS_Time_shifted;
%     if isempty(t_gps), continue; end
% 
%     % Convert time to relative duration
%     t_rel = seconds(t_gps - t_gps(1));
% 
%     % Extract speeds
%     v_gps = TB_gps(k).GPS_Speed;
%     v_rpm = TB_gps(k).GPS_Speed_RPM;
% 
%     % Plot both curves (different markers but SAME color per brake)
%     plot(t_rel, v_gps, '-', 'LineWidth', 1.2, 'DisplayName', sprintf('GPS %d', k));
%     plot(t_rel, v_rpm, '-','LineWidth', 1.2, 'DisplayName', sprintf('RPM %d', k));
% end
% 
% legend('GPS Speed','GPS Speed RPM','Location','bestoutside');
% hold off;
% 
% 
% %% ================== Finding Central Brake Cylinder ==================
% % Finding Central Brake Cylinder
% % --- Inputs ---
% T = Tfinal;              % has columns: BC_ID, WV_MeanPressure
% bc = categorical(T.BC_ID);         % group variable (BC identifiers)
% 
% % --- Coerce WV_MeanPressure to double (handles numeric or cell-with-scalar) ---
% n  = height(T);
% wv = nan(n,1);
% col = T.WV_MeanPressure;
% if isnumeric(col)
%     wv = double(col);
% end
% bc=bc(T.WV_MeanPressure>2);
% wv=wv(T.WV_MeanPressure>2);
% % --- 1) Visual check: boxchart WV_MeanPressure by BC_ID ---
% figure;
% boxchart(bc, wv);
% grid on;
% xlabel('BC\_ID');
% ylabel('WV Mean Pressure');
% title('WV\_MeanPressure by BC\_ID');
% %%
% % ================== BOXCHART WV vs BC_ID, grouped by BC_MaxPressure bins ==================
% T = Tfinal;
% 
% % --- Extract needed variables ---
% BC_ID = categorical(T.BC_ID);
% WV = T.WV_MeanPressure;
% Pipemax = T.Max_pressure_pipe;
% 
% % --- Convert to numeric if necessary ---
% n = height(T);
% if iscell(WV)
%     WVnum = nan(n,1);
%     for i = 1:n
%         val = WV{i};
%         if isempty(val), continue; end
%         if istable(val), val = val.(val.Properties.VariableNames{1}); end
%         if isduration(val), WVnum(i) = seconds(val(1));
%         elseif isnumeric(val), WVnum(i) = double(val(1));
%         end
%     end
%     WV = WVnum;
% end
% WV = WV(T.WV_MeanPressure>1.5);
% if iscell(Pipemax)
%     Pipemaxnum = nan(n,1);
%     for i = 1:n
%         val = Pipemax{i};
%         if isempty(val), continue; end
%         if istable(val), val = val.(val.Properties.VariableNames{1}); end
%         if isduration(val), Pipemaxnum(i) = seconds(val(1));
%         elseif isnumeric(val), Pipemaxnum(i) = double(val(1));
%         end
%     end
%     Pipemax = Pipemaxnum;
% end
% Pipemax = Pipemax(T.WV_MeanPressure>1.5);
% BC_ID = BC_ID(T.WV_MeanPressure>1.5);
% % --- Define pressure bins for BC_MaxPressure (adjust edges to your data range) ---
% edges = [0 0.6 1.5 3 3.5 5];   % [bar] → change as needed
% labels = {'<1','1–2','2–3','3–4','4–5'};
% BCmax_bin = discretize(Pipemax, edges, 'categorical', labels);
% 
% % --- Boxchart ---
% figure;
% boxchart(BC_ID, WV, 'GroupByColor', BCmax_bin);
% xlabel('BC ID');
% ylabel('WV Mean Pressure [bar]');
% title('WV Mean Pressure per BC, grouped by BC Max Pressure bins');
% % --- Legend title ---
% lgd = legend('show','Location','bestoutside');
% title(lgd,'Max Distributor Pressure');   % <-- ADD THIS
% grid on;
% %%
% % ================== BOXCHART BC_MaxPressure vs BC_ID, grouped by WV_MeanPressure bins ==================
% T = Tfinal;
% 
% % --- Extract needed variables ---
% BC_ID = categorical(T.BC_ID);
% WV    = T.WV_MeanPressure;
% BCmax = T.Max_pressure_cyl;
% 
% n = height(T);
% 
% % --- Convert WV to numeric if necessary ---
% if iscell(WV)
%     WVnum = nan(n,1);
%     for i = 1:n
%         val = WV{i};
%         if isempty(val), continue; end
%         if istable(val)
%             val = val.(val.Properties.VariableNames{1});
%         end
%         if isduration(val)
%             WVnum(i) = seconds(val(1));
%         elseif isnumeric(val)
%             WVnum(i) = double(val(1));
%         end
%     end
%     WV = WVnum;
% end
% 
% % --- Convert BCmax to numeric if necessary ---
% if iscell(BCmax)
%     BCmaxnum = nan(n,1);
%     for i = 1:n
%         val = BCmax{i};
%         if isempty(val), continue; end
%         if istable(val)
%             val = val.(val.Properties.VariableNames{1});
%         end
%         if isduration(val)
%             BCmaxnum(i) = seconds(val(1));
%         elseif isnumeric(val)
%             BCmaxnum(i) = double(val(1));
%         end
%     end
%     BCmax = BCmaxnum;
% end
% 
% % --- Optional: keep only WV > 2 bar (as you had before) ---
% mask   = WV > 1.5;
% BC_ID  = BC_ID(mask);
% WV     = WV(mask);
% BCmax  = BCmax(mask);
% 
% % --- Define WV_MeanPressure bins for coloring ---
% % adjust edges/labels as you like
% edgesWV  = [-inf 2 3 inf];          % [bar]
% labelsWV = {'< 2','2 – 3','> 3'};   % bin names
% 
% WV_bin = discretize(WV, edgesWV, 'categorical', labelsWV);
% 
% % --- Boxchart: BC max pressure on Y, colored by WV bins ---
% figure;
% boxchart(BC_ID, BCmax, 'GroupByColor', WV_bin);
% xlabel('BC ID');
% ylabel('BC Max Pressure [bar]');
% title('BC Max Pressure per BC, grouped by WV Mean Pressure bins');
% 
% lgd = legend('show','Location','bestoutside');
% title(lgd,'WV Mean Pressure [bar]');
% grid on;
% %%
% % ================== BOXCHART FP vs BC_ID, grouped by BC_MaxPressure bins ==================
% T = Tfinal;
% 
% % --- Extract needed variables ---
% BC_ID = categorical(T.BC_ID);
% FP = T.First_phase_mean_curvature;
% WVmean = T.WV_MeanPressure;
% 
% % --- Convert to numeric if necessary ---
% n = height(T);
% if iscell(FP)
%     FPnum = nan(n,1);
%     for i = 1:n
%         val = FP{i};
%         if isempty(val), continue; end
%         if istable(val), val = val.(val.Properties.VariableNames{1}); end
%         if isduration(val), FPnum(i) = seconds(val(1));
%         elseif isnumeric(val), FPnum(i) = double(val(1));
%         end
%     end
%     FP = FPnum;
% end
% 
% if iscell(WVmean)
%     WVnum = nan(n,1);
%     for i = 1:n
%         val = WVmean{i};
%         if isempty(val), continue; end
%         if istable(val), val = val.(val.Properties.VariableNames{1}); end
%         if isduration(val), WVnum(i) = seconds(val(1));
%         elseif isnumeric(val), WVnum(i) = double(val(1));
%         end
%     end
%     WVmean = WVnum;
% end
% % WVmean = WVmean(T.WV_MeanPressure>2);
% % BC_ID = BC_ID(T.WV_MeanPressure>2);
% % --- Define pressure bins for BC_MaxPressure (adjust edges to your data range) ---
% edges = [-inf 2 3 inf];   % [bar] → change as needed
% labels = {'<2 bar','2–3 bar','>3 bar'};
% BCmax_bin = discretize(WVmean, edges, 'categorical', labels);
% 
% % --- Boxchart ---
% figure;
% boxchart(BC_ID, FP, 'GroupByColor', BCmax_bin);
% xlabel('BC ID');
% ylabel('FP Mean Curvature []');
% title('FP Mean Curvature per BC, grouped by WV Mean Pressure');
% legend('show','Location','bestoutside');
% grid on;
% 
% %%
% % ================== FIRST PHASE BUILDUP VISUALIZATION ==================
% T_firstphase = Tfinal(Tfinal.BC_ID == '0x94',:);
% 
% vars = {'First_phase_half_time_ratio', ...
%         'First_phase_mean_curvature', ...
%         'First_phase_power'};
% 
% vars_1hz = {'First_phase_half_time_ratio_1hz', ...
%             'First_phase_mean_curvature_1hz', ...
%             'First_phase_power_1hz'};
% 
% % Brake type as categorical
% brakeCat = categorical(T_firstphase.EmergencyBrake_action, [0 1], {'Service','Emergency'});
% 
% % === Plot each feature ===
% figure('Name', ['First-phase features for BC ' char(T_firstphase.BC_ID(1))], 'Color', 'w');
% tiledlayout(2,2,'TileSpacing','compact');
% 
% for k = 1:numel(vars)
%     n = height(T_firstphase);
% 
%     % Convert to numeric (pass T_firstphase and n)
%     v10  = toDouble(T_firstphase.(vars{k}), n);
%     v1   = toDouble(T_firstphase.(vars_1hz{k}), n);
% 
%     % Combine both frequencies
%     allVals  = [v10; v1];                % corrected semicolon (vertical concat)
%     allBrake = [brakeCat; brakeCat];
%     rate     = [repmat("10Hz", n, 1); repmat("1Hz", n, 1)];
%     rate     = categorical(rate);
% 
%     % Remove NaN
%     valid = ~isnan(allVals);
%     allVals  = allVals(valid);
%     allBrake = allBrake(valid);
%     rate     = rate(valid);
% 
%     nexttile;
%     h = boxchart(allBrake, allVals, 'GroupByColor', rate);
% 
%     % --- Title with sensor ID ---
%     sensorID = char(T_firstphase.BC_ID(1)); % assumes all rows same ID
%     title(sprintf('%s — Sensor %s', strrep(vars{k}, '_', '\_'), sensorID), ...
%         'Interpreter','tex');
% 
%     ylabel('Value');
%     grid on;
% 
%     % ==========================
%     %   LEGEND LABELS (DYNAMIC)
%     % ==========================
% 
%     % 1) Get which rate categories are actually present in this tile
%     rateCatsPresent = categories(removecats(rate));   % e.g. {'10Hz','1Hz'}
% 
%     % 2) Build the dynamic label for the "10Hz" group
%     winSize = unique(windowSize_buildup);
%     if numel(winSize) == 1
%         % Example: "10 Hz (Window 15)"
%         winLabel10 = sprintf('%.0f Hz (Window %d)', fc_buildup, winSize);
%     else
%         % Fallback if inconsistent / multiple window sizes
%         winLabel10 = sprintf('%.0f Hz', fc_buildup);
%     end
% 
%     % 3) Map present categories -> legend strings
%     legendLabels = cell(size(rateCatsPresent));
%     for i = 1:numel(rateCatsPresent)
%         if strcmp(rateCatsPresent{i}, '10Hz')
%             legendLabels{i} = winLabel10;   % use fc_buildup + window size
%         elseif strcmp(rateCatsPresent{i}, '1Hz')
%             legendLabels{i} = '1 Hz';       % 1 Hz label stays simple
%         else
%             legendLabels{i} = rateCatsPresent{i};  % safety fallback
%         end
%     end
% 
%     % 4) Apply legend
%     legend(legendLabels, 'Location', 'best');
% end
% %% ================== FIRST PHASE (10 Hz) vs WV_MeanPressure BINS ==================
% vars_10hz = {'First_phase_half_time_ratio', ...
%              'First_phase_mean_curvature', ...
%              'First_phase_power'};
% 
% % Brake type (Standard / NonStandard)
% x = categorical(T_firstphase.Non_Standard_Braking, [0 1], {'Standard','NonStandard'});
% 
% % WV bins: [<2, 2–3, >3] with right-inclusive edges so 2→first bin, 3→second bin
% edges     = [-inf 2 3 inf];
% binLabels = ["<2","2–3",">3"];
% pressure  = T_firstphase.WV_MeanPressure;
% binIdx    = discretize(pressure, edges, 'IncludedEdge','right');
% g         = categorical(binIdx, 1:3, cellstr(binLabels));
% g         = reordercats(g, cellstr(binLabels));   % ensure legend/order is fixed
% 
% % Figure
% sensorID = char(T_firstphase.BC_ID(1));
% figure('Name', ['First-phase (10 Hz) vs WV bins — Sensor ' sensorID], 'Color','w');
% tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
% 
% % consistent colors per WV bin
% co = lines(numel(categories(g)));
% 
% for k = 1:numel(vars_10hz)
%     nexttile;
% 
%     % 10 Hz values -> numeric
%     n   = height(T_firstphase);
%     y10 = toDouble(T_firstphase.(vars_10hz{k}), n);
% 
%     % keep rows with valid y/x/color group
%     valid = isfinite(y10) & ~ismissing(x) & ~ismissing(g);
%     y10v  = y10(valid);
%     xv    = x(valid);
%     gv    = g(valid);
% 
%     if isempty(y10v)
%         text(0.5,0.5,'No data','HorizontalAlignment','center'); axis off; continue;
%     end
% 
%     h = boxchart(xv, y10v, 'GroupByColor', gv);
% 
%     % Drop unused categories, then list the ones actually present
%     catsPresent = categories(removecats(gv));   % <- present only
%     % If you defined the full ordered bin labels earlier, e.g.:
%     binLabels = ["<2","2–3",">3"];
%     co = lines(numel(binLabels));               % palette aligned to full set
% 
%     % Color each present group using the palette index of its label
%     for ii = 1:numel(h)
%         % map present label -> index in full label list
%         idx = find(strcmp(catsPresent{ii}, cellstr(binLabels)), 1);
%         if isempty(idx), idx = 1; end  % safety
%         h(ii).BoxFaceColor = co(idx,:);
%         h(ii).MarkerColor  = co(idx,:);
%     end
%     % ---- Axis labels / title ----
%     xlabel('Braking type');   % X label
%     ylabel(vars_10hz{k});     % Y label (optional)
%     title(strrep(vars_10hz{k}, '_', '\_'));  % nicer title (optional)
%     % Legend with only present categories
%     lg = legend(catsPresent, 'Location','northeastoutside');
%     lg.Title.String = 'WV MeanPressure';
% end
% 
% % === MEDIAN TABLE FOR FIRST-PHASE FEATURES (10 Hz vs 1 Hz) ===
% T_firstphase = Tfinal(Tfinal.BC_ID == '0x94',:);  % as before
% 
% vars = {'First_phase_half_time_ratio', ...
%         'First_phase_mean_curvature', ...
%         'First_phase_power'};
% 
% vars_1hz = {'First_phase_half_time_ratio_1hz', ...
%             'First_phase_mean_curvature_1hz', ...
%             'First_phase_power_1hz'};
% 
% nFeat = numel(vars);
% n     = height(T_firstphase);
% 
% med10 = nan(nFeat,1);   % median at 10 Hz
% med1  = nan(nFeat,1);   % median at 1 Hz
% 
% for k = 1:nFeat
%     % Convert to numeric exactly as in the plotting code
%     v10 = toDouble(T_firstphase.(vars{k}),      n);  % 10 Hz version
%     v1  = toDouble(T_firstphase.(vars_1hz{k}),  n);  % 1 Hz version
% 
%     % NaN-safe medians (ignore missing values)
%     med10(k) = median(v10, 'omitnan');
%     med1(k)  = median(v1,  'omitnan');
% end
% 
% % Build the table
% Median_FirstPhase = table( ...
%     vars(:), med10, med1, ...
%     'VariableNames', {'Feature','Median_10Hz','Median_1Hz'});
% 
% disp(Median_FirstPhase);
% 
% 
% %%
% % ================== FIRST PHASE BUILDUP VISUALIZATION ==================
% T_firstphase = Tfinal(Tfinal.BC_ID == '0x74',:);
% 
% vars = {'First_phase_half_time_ratio', ...
%         'First_phase_mean_curvature', ...
%         'First_phase_power'};
% 
% vars_1hz = {'First_phase_half_time_ratio_1hz', ...
%             'First_phase_mean_curvature_1hz', ...
%             'First_phase_power_1hz'};
% 
% % Brake type as categorical
% brakeCat = categorical(T_firstphase.EmergencyBrake_action, [0 1], {'Service','Emergency'});
% 
% % === Plot each feature ===
% figure('Name', ['First-phase features for BC ' char(T_firstphase.BC_ID(1))], 'Color', 'w');
% tiledlayout(2,2,'TileSpacing','compact');
% 
% for k = 1:numel(vars)
%     n = height(T_firstphase);
% 
%     % Convert to numeric (pass T_firstphase and n)
%     v10  = toDouble(T_firstphase.(vars{k}), n);
%     v1   = toDouble(T_firstphase.(vars_1hz{k}), n);
% 
%     % Combine both frequencies
%     allVals  = [v10; v1];                % corrected semicolon (vertical concat)
%     allBrake = [brakeCat; brakeCat];
%     rate     = [repmat("10Hz", n, 1); repmat("1Hz", n, 1)];
%     rate     = categorical(rate);
% 
%     % Remove NaN
%     valid = ~isnan(allVals);
%     allVals  = allVals(valid);
%     allBrake = allBrake(valid);
%     rate     = rate(valid);
% 
%     nexttile;
%     boxchart(allBrake, allVals, 'GroupByColor', rate);
% 
%     % --- Title with sensor ID ---
%     sensorID = char(T_firstphase.BC_ID(1)); % assumes all rows same ID
%     title(sprintf('%s — Sensor %s', strrep(vars{k}, '_', '\_'), sensorID), ...
%           'Interpreter','tex');
% 
%     ylabel('Value');
%     legend('show','Location','best');
%     grid on;
% end
% % ================== FIRST PHASE (10 Hz) vs WV_MeanPressure BINS ==================
% vars_10hz = {'First_phase_half_time_ratio', ...
%              'First_phase_mean_curvature', ...
%              'First_phase_power'};
% 
% % Brake type (Standard / NonStandard)
% x = categorical(T_firstphase.Non_Standard_Braking, [0 1], {'Standard','NonStandard'});
% 
% % WV bins: [<2, 2–3, >3] with right-inclusive edges so 2→first bin, 3→second bin
% edges     = [-inf 2 3 inf];
% binLabels = ["<2","2–3",">3"];
% pressure  = T_firstphase.WV_MeanPressure;
% binIdx    = discretize(pressure, edges, 'IncludedEdge','right');
% g         = categorical(binIdx, 1:3, cellstr(binLabels));
% g         = reordercats(g, cellstr(binLabels));   % ensure legend/order is fixed
% 
% % Figure
% sensorID = char(T_firstphase.BC_ID(1));
% figure('Name', ['First-phase (10 Hz) vs WV bins — Sensor ' sensorID], 'Color','w');
% tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
% 
% % consistent colors per WV bin
% co = lines(numel(categories(g)));
% 
% for k = 1:numel(vars_10hz)
%     nexttile;
% 
%     % 10 Hz values -> numeric
%     n   = height(T_firstphase);
%     y10 = toDouble(T_firstphase.(vars_10hz{k}), n);
% 
%     % keep rows with valid y/x/color group
%     valid = isfinite(y10) & ~ismissing(x) & ~ismissing(g);
%     y10v  = y10(valid);
%     xv    = x(valid);
%     gv    = g(valid);
% 
%     if isempty(y10v)
%         text(0.5,0.5,'No data','HorizontalAlignment','center'); axis off; continue;
%     end
% 
%     h = boxchart(xv, y10v, 'GroupByColor', gv);
% 
%     % Drop unused categories, then list the ones actually present
%     catsPresent = categories(removecats(gv));   % <- present only
%     % If you defined the full ordered bin labels earlier, e.g.:
%     binLabels = ["<2","2–3",">3"];
%     co = lines(numel(binLabels));               % palette aligned to full set
% 
%     % Color each present group using the palette index of its label
%     for ii = 1:numel(h)
%         % map present label -> index in full label list
%         idx = find(strcmp(catsPresent{ii}, cellstr(binLabels)), 1);
%         if isempty(idx), idx = 1; end  % safety
%         h(ii).BoxFaceColor = co(idx,:);
%         h(ii).MarkerColor  = co(idx,:);
%     end
%     % ---- Axis labels / title ----
%     xlabel('Braking type');   % X label
%     ylabel(vars_10hz{k});     % Y label (optional)
%     title(strrep(vars_10hz{k}, '_', '\_'));  % nicer title (optional)
%     % Legend with only present categories
%     lg = legend(catsPresent, 'Location','northeastoutside');
%     lg.Title.String = 'WV MeanPressure';
% end
% 
% %%
% % ================== FIRST PHASE BUILDUP VISUALIZATION ==================
% T_firstphase = Tfinal(Tfinal.BC_ID == '0xf5',:);
% 
% vars = {'First_phase_half_time_ratio', ...
%         'First_phase_mean_curvature', ...
%         'First_phase_power'};
% 
% vars_1hz = {'First_phase_half_time_ratio_1hz', ...
%             'First_phase_mean_curvature_1hz', ...
%             'First_phase_power_1hz'};
% 
% % Brake type as categorical
% brakeCat = categorical(T_firstphase.EmergencyBrake_action, [0 1], {'Service','Emergency'});
% 
% % === Plot each feature ===
% figure('Name', ['First-phase features for BC ' char(T_firstphase.BC_ID(1))], 'Color', 'w');
% tiledlayout(2,2,'TileSpacing','compact');
% 
% for k = 1:numel(vars)
%     n = height(T_firstphase);
% 
%     % Convert to numeric (pass T_firstphase and n)
%     v10  = toDouble(T_firstphase.(vars{k}), n);
%     v1   = toDouble(T_firstphase.(vars_1hz{k}), n);
% 
%     % Combine both frequencies
%     allVals  = [v10; v1];                % corrected semicolon (vertical concat)
%     allBrake = [brakeCat; brakeCat];
%     rate     = [repmat("10Hz", n, 1); repmat("1Hz", n, 1)];
%     rate     = categorical(rate);
% 
%     % Remove NaN
%     valid = ~isnan(allVals);
%     allVals  = allVals(valid);
%     allBrake = allBrake(valid);
%     rate     = rate(valid);
% 
%     nexttile;
%     boxchart(allBrake, allVals, 'GroupByColor', rate);
% 
%     % --- Title with sensor ID ---
%     sensorID = char(T_firstphase.BC_ID(1)); % assumes all rows same ID
%     title(sprintf('%s — Sensor %s', strrep(vars{k}, '_', '\_'), sensorID), ...
%           'Interpreter','tex');
% 
%     ylabel('Value');
%     legend('show','Location','best');
%     grid on;
% end
% % ================== FIRST PHASE (10 Hz) vs WV_MeanPressure BINS ==================
% vars_10hz = {'First_phase_half_time_ratio', ...
%              'First_phase_mean_curvature', ...
%              'First_phase_power'};
% 
% % Brake type (Standard / NonStandard)
% x = categorical(T_firstphase.Non_Standard_Braking, [0 1], {'Standard','NonStandard'});
% 
% % WV bins: [<2, 2–3, >3] with right-inclusive edges so 2→first bin, 3→second bin
% edges     = [-inf 2 3 inf];
% binLabels = ["<2","2–3",">3"];
% pressure  = T_firstphase.WV_MeanPressure;
% binIdx    = discretize(pressure, edges, 'IncludedEdge','right');
% g         = categorical(binIdx, 1:3, cellstr(binLabels));
% g         = reordercats(g, cellstr(binLabels));   % ensure legend/order is fixed
% 
% % Figure
% sensorID = char(T_firstphase.BC_ID(1));
% figure('Name', ['First-phase (10 Hz) vs WV bins — Sensor ' sensorID], 'Color','w');
% tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
% 
% % consistent colors per WV bin
% co = lines(numel(categories(g)));
% 
% for k = 1:numel(vars_10hz)
%     nexttile;
% 
%     % 10 Hz values -> numeric
%     n   = height(T_firstphase);
%     y10 = toDouble(T_firstphase.(vars_10hz{k}), n);
% 
%     % keep rows with valid y/x/color group
%     valid = isfinite(y10) & ~ismissing(x) & ~ismissing(g);
%     y10v  = y10(valid);
%     xv    = x(valid);
%     gv    = g(valid);
% 
%     if isempty(y10v)
%         text(0.5,0.5,'No data','HorizontalAlignment','center'); axis off; continue;
%     end
% 
%     h = boxchart(xv, y10v, 'GroupByColor', gv);
% 
%     % Drop unused categories, then list the ones actually present
%     catsPresent = categories(removecats(gv));   % <- present only
%     % If you defined the full ordered bin labels earlier, e.g.:
%     binLabels = ["<2","2–3",">3"];
%     co = lines(numel(binLabels));               % palette aligned to full set
% 
%     % Color each present group using the palette index of its label
%     for ii = 1:numel(h)
%         % map present label -> index in full label list
%         idx = find(strcmp(catsPresent{ii}, cellstr(binLabels)), 1);
%         if isempty(idx), idx = 1; end  % safety
%         h(ii).BoxFaceColor = co(idx,:);
%         h(ii).MarkerColor  = co(idx,:);
%     end
%     % ---- Axis labels / title ----
%     xlabel('Braking type');   % X label
%     ylabel(vars_10hz{k});     % Y label (optional)
%     title(strrep(vars_10hz{k}, '_', '\_'));  % nicer title (optional)
%     % Legend with only present categories
%     lg = legend(catsPresent, 'Location','northeastoutside');
%     lg.Title.String = 'WV MeanPressure';
% end
% 
% %% TPE Threshold
% figure;
% histfit(Total_Power_eff_data, 30, 'normal'); hold on;
% xline(Total_Power_eff_threshold, 'k--', 'LineWidth', 2, ...
%     'Label', '95% lower threshold', 'LabelVerticalAlignment', 'bottom');
% plot(linspace(min(Total_Power_eff_data), max(Total_Power_eff_data), 200), ...
%     normpdf(linspace(min(Total_Power_eff_data), max(Total_Power_eff_data), 200), mu, sigma) * ...
%     max(histcounts(Total_Power_eff_data, 30)) / max(normpdf(mu + (-4:0.01:4) * sigma, mu, sigma)), ...
%     'r-', 'LineWidth', 2);
% legend('Baseline Total Power eff', 'Gaussian fit', '95% lower threshold');
% title('Baseline Total Power eff with one-sided 95% threshold');
% grid on; hold off;

% %% plot_TBsets_phases
% S_Standard = TestBrakes_Struct;
% 
% fn = fieldnames(S_Standard);
% 
% Field = string(fn);
% Class = strings(numel(fn),1);
% Type  = strings(numel(fn),1);
% 
% for i = 1:numel(fn)
%     x1 = S_Standard(1).(fn{i});      % decide if this field is array
% 
%     if ~isscalar(x1)
%         Type(i)  = "skipped_array";
%         Class(i) = class(x1);
%         continue
%     end
% 
%     v = [S_Standard.(fn{i})];        % 27 scalars -> safe to concat
%     Class(i) = class(v);
% 
%     if islogical(v)
%         Type(i) = "logical";
%     elseif isnumeric(v) && all(ismember(unique(v(:)), [0 1]))
%         Type(i) = "binary01";
%     else
%         Type(i) = "other";
%     end
% end
% 
% T = table(Field, Class, Type);
% disp(T)


%%
% hfig_power = plot_TBsets_phases(S_Standard, 'Total_power_efficiency');
%%
% hfig_tpe = plot_TBsets_phases(TBsets_out_concat_struct, 'Total_power_efficiency');

%%
% writetable(Tfinal, 'Tfinal_15hz_win5.csv');
flagNames = [
    "SV_Error"
    "EmergencyBrake"
    "Non_Standard_Braking"
    "UR_Error"
    "DS_Error"
    "UB_Error"
    "Gateway_VB_Error"
    "Gateway_CB_Error"
    "First_phase_error"
    "MBP_Sensor_error"
    "GPS_SensorError"
    "BC_SensorError"
    "BC_BadStart"
    "WV_SensorError"
];

% MBP-only (phase-level / global) vs per-cell flags
phaseFlagNames = [
    "SV_Error"
    "EmergencyBrake"
    "GPS_SensorError"
    "Gateway_VB_Error"
    "Gateway_CB_Error"
    "MBP_Sensor_error"
    "MBP_PhaseClassification_error"
];

cellFlagNames = setdiff(flagNames, phaseFlagNames, "stable");

% hFigs = plot_Diagnosis(TBsets_out, ...
%     'mbpCellIdx', 1, ...
%     'assumeSecFromMBPStart', true, ...
%     'plotFallbackWholeTrace', true, ...
%     'flagNames', flagNames, ...
%     'phaseFlagNames', phaseFlagNames, ...
%     'cellFlagNames', cellFlagNames);


% hFigs = plot_Diagnosis(S_raw, ...
    % 'flagNames', flagNames);

hFigs = plot_Diagnosis_RawPressure(TBsets_out, Nodo_filtered, ...
    'flagNames', flagNames, ...
    'phaseFlagNames', phaseFlagNames, ...
    'cellFlagNames', cellFlagNames, ...
    'overlayNodo', true, ...
    'overlayTypes', ["MBP","BC","WV"]);

%%
% writetable(Tfinal, 'Tfinal_15hz_win5.csv');

%% ----------------- helpers -----------------
% === Helper to convert any column to numeric ===
function x = toDouble(col, n)
    x = nan(n,1);
    if isnumeric(col)
        x = double(col);
    elseif isduration(col)
        x = seconds(col);
    elseif iscell(col)
        for i = 1:n
            val = col{i};
            if isempty(val), continue; end
            if istable(val)
                val = val.(val.Properties.VariableNames{1});
            end
            if isduration(val)
                x(i) = seconds(val(1));
            elseif isnumeric(val)
                x(i) = double(val(1));
            end
        end
    end
end

function v = sget(Si, fieldName)
    if isfield(Si, fieldName)
        v = Si.(fieldName);
    else
        v = [];
    end
end

function t = clean_time(t, tMin, tMax)
    if isempty(t) || ~isdatetime(t)
        t = [];
        return;
    end
    valid = (t >= tMin) & (t <= tMax);
    t = t(valid);
end

function t0 = iGetStartTime(s)
    t0 = NaT;
    if isfield(s,'MBP_StartTime') && isdatetime(s.MBP_StartTime)
        t0 = s.MBP_StartTime;
    elseif isfield(s,'MBP_Time') && isdatetime(s.MBP_Time) && ~isempty(s.MBP_Time)
        tt = s.MBP_Time(:);
        tt = tt(~ismissing(tt));
        if ~isempty(tt), t0 = tt(1); end
    end
end

function val = iGetScalar(Si, fld, def)
    if isfield(Si, fld)
        v = Si.(fld);
        if isscalar(v) && (islogical(v) || isnumeric(v))
            val = double(v);
            return;
        end
        if isempty(v)
            val = def; return;
        end
        vi = v(1); % fallback
        if (islogical(vi) || isnumeric(vi)) && isscalar(vi)
            val = double(vi);
            return;
        end
    end
    val = def;
end

%% ===== local helper: extract ID from Test sensor struct =====
function sid = extractIDFromTestSensor(S)
% Try to read a human-readable sensor ID from Test(j) entry.
    sid = "";
    if isfield(S,'ID')
        v = S.ID;
    elseif isfield(S,'Nodo')
        v = S.Nodo;
    else
        v = [];
    end

    if isstring(v)
        sid = v(1);
    elseif ischar(v)
        sid = string(v);
    elseif iscell(v) && ~isempty(v)
        sid = string(v{1});
    elseif ~isempty(v)
        sid = string(v);
    end
end
