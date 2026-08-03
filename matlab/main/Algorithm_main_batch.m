%% Algorithm Experiment 2  — Batch runner (multi-file)
paths = startup();
% -------- Choose multiple *.mat files --------
[files, path] = uigetfile('*.mat', 'Select one or more Nodo MAT files', paths.interim, 'MultiSelect', 'on');

if isequal(files,0)
    disp('User canceled.');
    return;
end

% Normalize selection to a cellstr list
if ischar(files) || isstring(files)
    files = cellstr(files);
end

% Centralized feature-output directory.
ROOT_OUT = paths.features;
if ~exist(ROOT_OUT, 'dir'), mkdir(ROOT_OUT); end

% -------- Batch loop --------
for k = 1:numel(files)
    try
        %% ============== PER-FILE CONTEXT ==============
        file = files{k};                               % keep 'file' for your code below
        fullFileName = fullfile(path, file);
        fprintf('\n==== [%d/%d] Loading: %s ====\n', k, numel(files), fullFileName);

        % Reset key workspace variables used by the pipeline (do NOT clear files/path/k)
        clear Test Nodo Nodo_filtered TestBrake TBsets TBsets_out TBsets_out_filtered ...
              TestBrakes_table pairingTable datasetKey regFile usedMethod refPhase scores report;

        % Load .mat
        S = load(fullFileName);                        % safer than bare load into workspace
        % Expect either 'Nodo_filtered' or 'Nodo'
        if isfield(S,'Nodo_filtered')
            Nodo_filtered = S.Nodo_filtered;           
        elseif isfield(S,'Nodo')
            Nodo_filtered = S.Nodo;                    
        else
            warning('File %s has neither Nodo_filtered nor Nodo. Skipping.', file);
            continue;
        end
        fprintf('Loaded.\n');

        % -------- Your original script starts here (unchanged) --------
        % Replace your original "clear; close all; clc;" with this lighter reset:
        close all; clc;
        Resample    = false;           % keep your flags
        plotFigure  = false;

        % -------- Filtering params (unchanged) --------
        Fs = 40; fc = 1; dt = 1/Fs; filterOrder = 1;
        windowSize = 20; windowGrad = 20;
        [b,a] = butter(filterOrder, fc/(Fs/2));

        fc_buildup = 10;
        [b_buildup, a_buildup] = butter(filterOrder, fc_buildup/(Fs/2));
        windowSize_buildup = 5;

        % The rest of your code below expects:
        %   Test = Nodo_filtered; and then runs filtering/detection/etc.
        Test = Nodo_filtered;
        numTests = numel(Test);

        %% --- Data filtering ---
        for j = 1:numTests
            N = length(Test(j).Time);

            Test(j).Pressure_mean_filter        = zeros(N, 1);
            Test(j).Pressure_filter             = zeros(N, 1);
            Test(j).Gradient_pressure           = zeros(N, 1);
            Test(j).Gradient_pressure_filtered  = zeros(N, 1);

            Test(j).Pressure_filter_10Hz             = zeros(N, 1);

            movingSum = 0; movingSum_grad = 0;
            buffer = zeros(windowSize,1); buffer_grad = zeros(windowGrad,1);
            bufferIndex = 1; bufferIndex_grad = 1;

            % Moving average buffer (10 Hz gradient) — causal
            % buffers before the loop
            movingSum10   = 0;
            buffer10      = zeros(windowSize_buildup,1);
            bufferIdx10   = 1;

            for c1 = 1:N
                newVal = Test(j).Pressure(c1);
                movingSum = movingSum - buffer(bufferIndex) + newVal;
                buffer(bufferIndex) = newVal;
                bufferIndex = mod(bufferIndex, windowSize) + 1;
                Test(j).Pressure_mean_filter(c1) = movingSum / min(c1, windowSize);

                if c1 == 1
                    Test(j).Pressure_filter(c1) = b(1) * Test(j).Pressure_mean_filter(c1);
                else
                    Test(j).Pressure_filter(c1) = b(1)*Test(j).Pressure_mean_filter(c1) + ...
                        b(2)*Test(j).Pressure_mean_filter(c1-1) - a(2)*Test(j).Pressure_filter(c1-1);
                end

                if c1 > 1
                    Test(j).Gradient_pressure(c1) = (Test(j).Pressure_filter(c1) - Test(j).Pressure_filter(c1-1)) / dt;
                else
                    Test(j).Gradient_pressure(c1) = 0;
                end

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

            end
        end

        %% BRAKING PHASE (your call)
        [TestBrake, ~, ~] = detect_braking_struct_beta(Test);
        % [TestBrake, ~, ~] = detect_brakingaction_samples(Test);

        %% Reference phase & healthy sensors (your calls)
        [refPhase, scores, report] = pick_reference_phase(TestBrake);
        fprintf('Reference Phase: %d\n', refPhase);
        HealthySensorList = Collect_Healthy_SensorData(TestBrake);

        [TBsets, pairingTable, datasetKey, regFile, usedMethod] = ...
            build_TestBrake_sets(TestBrake, HealthySensorList, file, refPhase);
        disp(pairingTable);

        %% Feature Extraction Phase classification
        % inside this is a separate core function to detect:
        % 1. MBP braking subphases (detect_MBP_pipe_subphases.m)
        % 2. BC braking subphases (detect_BC_cyl_subphases.m)
        TBsets_out = detect_subphases_sets(TBsets, ...
            'MBPArgs', {'GradStart', -0.05, 'GradRelease', 0.05, 'DistributorIdleThresh', 0.05}, ...
            'BCArgs',  {'GradStartPos', +0.05, 'GradReleaseNeg', -0.05, 'EndPressure', 0.40}, ...
            'Verbose', true);
        
        % Phase Classification Post Processing
        % Obtain Total_power_efficiency and Energy_ratio from the cell array
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

        % === Save TBsets_out using same base filename, but into ROOT_OUT ===
        [~, baseFile, ~] = fileparts(char(file));
        outFile = fullfile(ROOT_OUT, baseFile + "_output.mat");
        save(outFile, 'TBsets_out', '-v7.3');
        fprintf('Saved TBsets_out to %s\n', outFile);

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

        % % Insert into master (keeps one copy only, sorted by Start_brake_time)
        % TestBrake_Master = update_brake_master( ...
        %     TestBrakes_table, ...                 % your per-run table
        %     'AllRunPath',      'TestBrake_Master.mat', ...
        %     'PerFolderPattern','%s_Master.mat', ...   % -> 'Dati10_Master.mat', etc.
        %     'WriteCSV',        false ...              % set true to also emit CSV files
        %     );

    catch ME
        % Robust per-file error handling so the batch continues
        warning('Error in file %s: %s', file, ME.message);
        if ~isempty(ME.stack)
            stk = ME.stack(1);
            fprintf('  at %s (line %d)\n', stk.name, stk.line);
        end
        fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks','off'));
        % Continue with next file
    end
end

fprintf('\nAll selected files processed. Output dir: %s\n', ROOT_OUT);
