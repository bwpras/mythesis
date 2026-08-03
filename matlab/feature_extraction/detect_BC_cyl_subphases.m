function TestBrake = detect_BC_cyl_subphases(TestBrake, varargin)
% DETECT_BC_CYL_SUBPHASES — BC subphases with MBP-like state machine
% States: idle → buildup → braking ↔ releasing
% - Start buildup when dP/dt > GradStartPos
% - Switch to releasing when dP/dt < GradReleaseNeg
% - If releasing and dP/dt > GradStartPos, merge that release chunk back into brake
% - Release ends when pressure < EndPressure (default 0.40 bar),
%   but only if the episode ever reached ≥ EndPressure during buildup/braking.
%
% Holding is derived from the brake array by the 90% rule (like MBP).
% - timing is duration

%% -------- Parameters --------
parser = inputParser;
addParameter(parser,'GradStartPos',         +0.05);  % bar/s: enter buildup if dP/dt >
addParameter(parser,'GradReleaseNeg',       -0.05);  % bar/s: enter releasing if dP/dt <
addParameter(parser,'EndPressure',           0.40);  % bar  : release ends when P < (if episode reached threshold)
addParameter(parser,'EndBuildup',            0.40);  % bar
addParameter(parser,'UseProvidedGradient',   true);
addParameter(parser,'ActionThresh',          0.60);  % bar  : flag as braking action
addParameter(parser,'TailTrimPressure', 0.05);       % bar trim tail if grad<0 & P< this
addParameter(parser,'idle_controlwindow_s', 30);       
addParameter(parser,'idle_dp', 0.4);       

parse(parser,varargin{:});
cfg = parser.Results;



% --- flatness counter config (change if needed) ---
flatGrad        = 0.01;   % |gradient_k| tolerance to consider "flat"
flatMaxCount   = 210;     % consecutive samples required to flip to 'braking'
flatCount      = 0;      % runtime counter (consecutive flat samples)

for phaseIdx = 1:numel(TestBrake)
    % Grab values (handle [], NaN, or short vectors gracefully)
    BC_P_End = []; if isfield(TestBrake(phaseIdx),'BC_Pressure_at_MBP_End'), BC_P_End = TestBrake(phaseIdx).BC_Pressure_at_MBP_End; end

    % Any sample beyond threshold? (NaNs and [] are harmless here)
    flag = any(BC_P_End > cfg.EndPressure);

    % Store as logical (use double(flag) if you prefer 0/1)
    TestBrake(phaseIdx).UR_Error = logical(flag);

    %% -------- Guards on required inputs --------
    hasTime    = isfield(TestBrake(phaseIdx),'BC_Time')     && ~isempty(TestBrake(phaseIdx).BC_Time);
    hasPress   = isfield(TestBrake(phaseIdx),'BC_Pressure') && ~isempty(TestBrake(phaseIdx).BC_Pressure);
    %% -------- Inputs --------
    % ---- Common init for both branches ----

    timeBC     = TestBrake(phaseIdx).BC_Time(:);
    pressureBC = TestBrake(phaseIdx).BC_Pressure(:);
    pressureBC10hz = TestBrake(phaseIdx).BC_Pressure10hz(:);
    gradBC     = TestBrake(phaseIdx).BC_Gradient(:);
    emptyDT = datetime.empty(0,1);
    emptyDB = double.empty(0,1);

    if ~(hasTime && hasPress)
        % Minimal, type-safe empties (datetime/double)
        TestBrake(phaseIdx).Brake_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Brake_pressure_cyl = emptyDB;

        TestBrake(phaseIdx).Buildup_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Buildup_pressure_cyl = emptyDB;

        TestBrake(phaseIdx).Holding_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Holding_pressure_cyl = emptyDB;

        TestBrake(phaseIdx).Release_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Release_pressure_cyl = emptyDB;

        TestBrake(phaseIdx).Start_brake_time_cyl = NaT;
        TestBrake(phaseIdx).End_brake_time_cyl   = NaT;

        TestBrake(phaseIdx).First_phase_time     = emptyDT;
        TestBrake(phaseIdx).First_phase_pressure = emptyDB;
        TestBrake(phaseIdx).First_phase_gradient = emptyDB;
        TestBrake(phaseIdx).End_first_phase_time = NaT;

        TestBrake(phaseIdx).First_phase_time_1hz     = emptyDT;
        TestBrake(phaseIdx).First_phase_pressure_1hz = emptyDB;
        TestBrake(phaseIdx).First_phase_gradient_1hz = emptyDB;
        TestBrake(phaseIdx).End_first_phase_time_1hz = NaT;

        TestBrake(phaseIdx).Brake_timing_cyl   = NaN;
        TestBrake(phaseIdx).Brake_energy_cyl   = NaN;
        TestBrake(phaseIdx).Brake_power_cyl    = NaN;
        TestBrake(phaseIdx).Total_timing_cyl   = NaN;
        TestBrake(phaseIdx).Total_energy_cyl   = NaN;
        TestBrake(phaseIdx).Total_power_cyl    = NaN;
        TestBrake(phaseIdx).Non_Standard_Braking  = 0;

        TestBrake(phaseIdx).Buildup_timing_cyl   = NaN;
        TestBrake(phaseIdx).Buildup_gradient_cyl = NaN;
        TestBrake(phaseIdx).Buildup_energy_cyl   = NaN;
        TestBrake(phaseIdx).Buildup_power_cyl    = NaN;

        TestBrake(phaseIdx).Holding_timing_cyl = NaN;
        TestBrake(phaseIdx).Holding_energy_cyl = NaN;
        TestBrake(phaseIdx).Holding_power_cyl  = NaN;

        TestBrake(phaseIdx).Release_timing_cyl   = NaN;
        TestBrake(phaseIdx).Release_gradient_cyl = NaN;
        TestBrake(phaseIdx).Release_energy_cyl   = NaN;
        TestBrake(phaseIdx).Release_power_cyl    = NaN;

        TestBrake(phaseIdx).Max_pressure_cyl          = NaN;
        TestBrake(phaseIdx).Brake_action_cyl          = 0;
        TestBrake(phaseIdx).Mean_cyl                  = NaN;
        TestBrake(phaseIdx).Std_cyl                   = NaN;
        TestBrake(phaseIdx).Consecutive_braking_cyl   = 0;

        continue
    end

    %% -------- State machine --------
    % abnormalCase = (TestBrake(phaseIdx).Consecutive_braking_pipe > 0) || (TestBrake(phaseIdx).BC_LowBraking == 1);
    abnormalCase = TestBrake(phaseIdx).BC_NormalBraking == 0;
    TestBrake(phaseIdx).Non_Standard_Braking = abnormalCase;
    % ==== original state machine ====
    % Standard braking action
    brake_time_series     = emptyDT; brake_pressure_series     = emptyDB;
    buildup_time_series   = emptyDT; buildup_pressure_series   = emptyDB;
    release_time_series   = emptyDT; release_pressure_series   = emptyDB;
    brake_gradient_series   = emptyDB;
    buildup_gradient_series = emptyDB;
    release_gradient_series = emptyDB;
    buildup_pressure10hz_series = emptyDB;

    EmergencyBraking = (TestBrake(phaseIdx).EmergencyBrake == 1);
    DS_ErrorBuildup  = false;
    DS_ErrorRelease  = false;

    brake_duration_s   = 0; brake_energy = 0;
    release_duration_s = 0; release_energy = 0;

    maxPressure = -inf; sumPressure = 0; sumPressureSq = 0; numSamples = 0;
    consecutiveBrakingCount = 0;
    idlebuf_active   = false;    % buffering idle samples between release end and next action
    idlebuf_time     = emptyDT;
    idlebuf_press    = emptyDB;
    idlebuf_grad     = emptyDB;


    state = 'idle';
    segmentStartIndex = 2;
    buildupEnd = false;
    firstbuildupEnd = false;
    flatCount  = 0;                        % <-- initialize
    controlwindow = false;
    consec_braking = false;
    for kk = 2:numel(timeBC)
        time_k     = timeBC(kk);
        pressure_k = pressureBC(kk);
        pressure10hz_k = pressureBC10hz(kk);
        gradient_k = gradBC(kk);

        dtS = seconds(timeBC(kk) - timeBC(kk-1));
        if ~isfinite(dtS) || dtS <= 0, dtS = 0; end

        switch state
            case 'idle'
                consec_braking = false;
                if buildupEnd && (gradient_k > cfg.GradStartPos) && ~controlwindow
                    controlwindow = true;
                    idle_t0    = timeBC(kk-1);        % previous sample
                    % idle_p0    = pressureBC(kk-1);
                    % idle_pmax  = idle_p0;
                end
                % --- NEW: keep buffering idle samples if active ---
                if idlebuf_active
                    idlebuf_time(end+1,1)  = time_k;
                    idlebuf_press(end+1,1) = pressure_k;
                    idlebuf_grad(end+1,1)  = gradient_k;
                end
                if controlwindow
                    % if pressure_k > idle_pmax
                    %     idle_pmax = pressure_k;
                    % end
                    % deltaP  = idle_pmax - idle_p0;
                    elapsed = seconds(time_k - idle_t0);

                    if pressure_k >= cfg.idle_dp
                        consec_braking = true;
                        controlwindow = false;
                    elseif elapsed >= cfg.idle_controlwindow_s
                        controlwindow = false;
                        idlebuf_active = false;
                        idlebuf_time   = emptyDT;
                        idlebuf_press  = emptyDB;
                        idlebuf_grad   = emptyDB;
                    end

                end
                if gradient_k > cfg.GradStartPos && buildupEnd && consec_braking
                    % Merge previously collected release back into braking
                    state = 'braking';

                    % Append release data onto braking series
                    % brake_time_series       = [brake_time_series;     release_time_series];
                    % brake_pressure_series   = [brake_pressure_series; release_pressure_series];
                    % brake_gradient_series   = [brake_gradient_series; release_gradient_series];
                    
                    % Append release + buffered idle valley onto braking series
                    brake_time_series     = [brake_time_series;     release_time_series;     idlebuf_time];
                    brake_pressure_series = [brake_pressure_series; release_pressure_series; idlebuf_press];
                    brake_gradient_series = [brake_gradient_series; release_gradient_series; idlebuf_grad];


                    % Carry over time/energy from release into braking, then reset release accumulators
                    brake_duration_s        = brake_duration_s + release_duration_s;
                    brake_energy            = brake_energy   + release_energy;

                    release_time_series     = emptyDT;
                    release_pressure_series = emptyDB;
                    release_gradient_series = emptyDB;
                    release_duration_s      = 0;
                    release_energy          = 0;

                    idlebuf_active = false;
                    idlebuf_time   = emptyDT;
                    idlebuf_press  = emptyDB;
                    idlebuf_grad   = emptyDB;


                    segmentStartIndex       = kk-1;  % continue from last sample
                    consecutiveBrakingCount = consecutiveBrakingCount + 1;

                    brake_time_series(end+1,1)     = timeBC(kk-1);
                    brake_pressure_series(end+1,1) = pressureBC(kk-1);
                    brake_gradient_series(end+1,1) = gradBC(kk-1);

                    buildupEnd = false;   % consume the flag
                    firstbuildupEnd = false;
                    % controlwindow  = false;
                    % consec_braking = false;

                % go to next sample; 'braking' state will handle it
                elseif gradient_k > cfg.GradStartPos && ~buildupEnd
                    % NEW: discard buffered idle if we are starting a fresh event
                    idlebuf_active = false;
                    idlebuf_time   = emptyDT;
                    idlebuf_press  = emptyDB;
                    idlebuf_grad   = emptyDB;
       
                    state = 'buildup';
                    segmentStartIndex = kk-1;
                    buildupEnd = false;
                    firstbuildupEnd = false;
                    flatCount  = 0;
                end

            case 'buildup'
                segTimes = timeBC(segmentStartIndex:kk);
                segPress = pressureBC(segmentStartIndex:kk);

                brake_time_series(end+1,1)      = time_k;
                brake_pressure_series(end+1,1)  = pressure_k;
                brake_gradient_series(end+1,1)  = gradient_k;
                buildup_time_series(end+1,1)    = time_k;
                buildup_pressure_series(end+1,1)= pressure_k;
                buildup_gradient_series(end+1,1)= gradient_k;

                if TestBrake(phaseIdx).BC_BadStart == 0 && ~firstbuildupEnd && pressureBC10hz(1) <0.1
                    buildup_pressure10hz_series(end+1,1)=pressure10hz_k;
                end
                if pressure_k >= cfg.EndBuildup
                    firstbuildupEnd = true;
                end
                brake_duration_s = brake_duration_s + dtS;

                trel = seconds(segTimes - segTimes(1));
                if numel(segTimes)>=2
                    brake_energy = brake_energy + trapz(trel, segPress);
                end
                segmentStartIndex = kk-1;

                if pressure_k >= cfg.ActionThresh     % keep one threshold
                    buildupEnd = true;
                end

                if abs(gradient_k) <= flatGrad
                    flatCount = flatCount + 1;
                else
                    flatCount = 0;
                end

                % if flatCount >= flatMaxCount && buildupEnd
                %     state = 'braking';
                %     segmentStartIndex = kk-1;
                %     flatCount = 0;
                % end
                if flatCount >= flatMaxCount && buildupEnd
                    state = 'releasing';
                    segmentStartIndex = kk-1;
                    flatCount = 0;
                end

                if gradient_k < cfg.GradReleaseNeg && buildupEnd
                    state = 'releasing';
                    segmentStartIndex = kk-1;
                    flatCount = 0;
                end
                
            case 'braking'
                segTimes = timeBC(segmentStartIndex:kk);
                segPress = pressureBC(segmentStartIndex:kk);

                brake_time_series(end+1,1)     = time_k;
                brake_pressure_series(end+1,1) = pressure_k;
                brake_gradient_series(end+1,1) = gradient_k;

                brake_duration_s = brake_duration_s + dtS;

                trel = seconds(segTimes - segTimes(1));
                if numel(segTimes)>=2
                    brake_energy = brake_energy + trapz(trel, segPress);
                end
                segmentStartIndex = kk-1;

                if pressure_k >= cfg.EndPressure
                    buildupEnd = true;
                end

                if gradient_k < cfg.GradReleaseNeg && buildupEnd
                    release_time_series(end+1,1)     = timeBC(kk-1);
                    release_pressure_series(end+1,1) = pressureBC(kk-1);
                    release_gradient_series(end+1,1) = gradBC(kk-1);
                    state = 'releasing';
                    segmentStartIndex = kk-1;
                    % seed release with kk-1

                end

            case 'releasing'
                segTimes = timeBC(segmentStartIndex:kk);
                segPress = pressureBC(segmentStartIndex:kk); 
                release_time_series(end+1,1)     = timeBC(kk-1);
                release_pressure_series(end+1,1) = pressureBC(kk-1);
                release_gradient_series(end+1,1) = gradBC(kk-1);

                release_duration_s = release_duration_s + dtS;

                trel = seconds(segTimes - segTimes(1));
                if numel(segTimes)>=2
                    release_energy = release_energy + trapz(trel, segPress);
                end
                segmentStartIndex = kk-1;
                % Track flat gradient during release
                if abs(gradient_k) <= flatGrad
                    flatCount = flatCount + 1;
                else
                    flatCount = 0;
                end

                % **IMPROVED: Only reclassify if pressure is BOTH flat AND high**
                % Check if we've been flat for a while AND pressure hasn't dropped significantly
                if flatCount >= flatMaxCount && numel(release_pressure_series) >= flatMaxCount
                    % Calculate pressure drop since entering release state
                    pressureAtReleaseStart = release_pressure_series(1);
                    pressureDrop = pressureAtReleaseStart - pressure_k;

                    % Define a threshold - if pressure hasn't dropped much, it's sustained braking
                    % Adjust this threshold based on your data (e.g., 0.05 bar, 0.1 bar, etc.)
                    minPressureDropThreshold = 0.05;  % bar - tune this value

                    % Only reclassify if pressure drop is minimal
                    if pressureDrop < minPressureDropThreshold
                        % Reclassify this release segment as braking
                        state = 'braking';

                        brake_time_series      = [brake_time_series;     release_time_series];
                        brake_pressure_series  = [brake_pressure_series; release_pressure_series];
                        brake_gradient_series  = [brake_gradient_series; release_gradient_series];
                        release_time_series    = emptyDT;
                        release_pressure_series= emptyDB;
                        release_gradient_series= emptyDB;

                        brake_duration_s   = brake_duration_s + release_duration_s;
                        release_duration_s = 0;
                        brake_energy       = brake_energy + release_energy;
                        release_energy     = 0;

                        segmentStartIndex = kk-1;
                        flatCount = 0;
                        consecutiveBrakingCount = consecutiveBrakingCount + 1;
                    end
                
                
                elseif gradient_k > cfg.GradStartPos
                    % bounce back to braking: merge release into braking
                    state = 'braking';

                    brake_time_series      = [brake_time_series;     release_time_series];
                    brake_pressure_series  = [brake_pressure_series; release_pressure_series];
                    brake_gradient_series  = [brake_gradient_series; release_gradient_series];
                    release_time_series    = emptyDT;
                    release_pressure_series= emptyDB;
                    release_gradient_series= emptyDB;

                    brake_duration_s   = brake_duration_s + release_duration_s;
                    release_duration_s = 0;
                    brake_energy       = brake_energy + release_energy;
                    release_energy     = 0;

                    segmentStartIndex = kk-1;
                    consecutiveBrakingCount = consecutiveBrakingCount + 1;

                elseif (pressure_k < cfg.EndPressure) && buildupEnd
                    % end of release
                    state = 'idle';
                    segmentStartIndex = kk-1;
                    flatCount  = 0;

                    % --- NEW: start idle buffer from boundary sample (kk-1) ---
                    idlebuf_active = true;
                    idlebuf_time   = emptyDT;
                    idlebuf_press  = emptyDB;
                    idlebuf_grad   = emptyDB;

                    idlebuf_time(end+1,1)  = timeBC(kk-1);
                    idlebuf_press(end+1,1) = pressureBC(kk-1);
                    idlebuf_grad(end+1,1)  = gradBC(kk-1);
                end
        end

        % running stats
        if pressure_k > maxPressure, maxPressure = pressure_k; end
        sumPressure   = sumPressure   + pressure_k;
        sumPressureSq = sumPressureSq + pressure_k^2;
        numSamples    = numSamples + 1;
    end

    %% -------- Split Holding using 90% of Buildup peak --------
    if ~isempty(buildup_pressure_series)
        threshold90 = 0.9 * max(buildup_pressure_series, [], 'omitnan');
        if isfinite(threshold90)
            endBuildupIdx = find(buildup_pressure_series >= threshold90, 1, 'first');
        else
            endBuildupIdx = [];
        end
    else
        endBuildupIdx = [];
    end

    %% -------- FirstBuildup extraction (sample→time using Fs) --------
    % ===== τ (seconds) from synthetic uniform time at Fs =====
    Fs = 40;                    % your known sampling rate
    dt = 1/Fs;
    if ~isempty(buildup_pressure10hz_series)
        errorBuildup = buildup_pressure10hz_series(1) > 0.1;
        TestBrake(phaseIdx).First_phase_error = errorBuildup;
        endFirstBuildupIdx = find(buildup_pressure10hz_series >= cfg.EndBuildup, 1, 'first');
        endFirstBuildupIdx_1hz = find(buildup_pressure_series >= cfg.EndBuildup, 1, 'first');
    else
        errorBuildup = 0;
        TestBrake(phaseIdx).First_phase_error = errorBuildup;
        endFirstBuildupIdx = [];
        endFirstBuildupIdx_1hz = [];
    end
    if ~isempty(endFirstBuildupIdx_1hz) && endFirstBuildupIdx_1hz >=2
        FP_p_1hz = buildup_pressure_series(1:endFirstBuildupIdx_1hz);
        FP_t_1hz = buildup_time_series(1:endFirstBuildupIdx_1hz);
        % 1 hz
        % N_1hz = numel(FP_p_1hz);
        % n_1hz = (0:N_1hz-1)';
        % t_1hz = n_1hz*dt;
        TestBrake(phaseIdx).First_phase_pressure_1hz = FP_p_1hz;
        t_dt = buildup_time_series(1:endFirstBuildupIdx_1hz);   % datetime
        t_s  = seconds(t_dt - t_dt(1));                         % numeric seconds
        TestBrake(phaseIdx).First_phase_time_1hz      = t_dt;   % store datetime
        TestBrake(phaseIdx).First_phase_time_s_1hz    = t_s;    % store seconds axis
        first_phase_timing_1hz = t_s(end) - t_s(1);            % numeric seconds
        TestBrake(phaseIdx).First_phase_timing_1hz = first_phase_timing_1hz;
        % 1 hz
        % dtD_1hz  = seconds(FP_tD_1hz - FP_tD_1hz(1));
        % if dtD_1hz <= 0, dtD_1hz = dt; end

        TestBrake(phaseIdx).End_first_phase_time_1hz     = FP_t_1hz(end);
        TestBrake(phaseIdx).End_first_phase_pressure_1hz = FP_p_1hz(end);
        first_phase_gradient_1hz  = gradient(FP_p_1hz, t_s);
        first_phase_curvature_1hz = gradient(first_phase_gradient_1hz, t_s);
        first_phase_true_curvature_1hz = first_phase_curvature_1hz ./ (1 + first_phase_gradient_1hz.^2).^(3/2);
        TestBrake(phaseIdx).First_phase_gradient_1hz   = first_phase_gradient_1hz;
        TestBrake(phaseIdx).First_phase_curvature_1hz  = first_phase_curvature_1hz;
        TestBrake(phaseIdx).First_phase_curvNorm_1hz   = first_phase_true_curvature_1hz;
        TestBrake(phaseIdx).First_phase_mean_curvature_1hz = mean(abs(first_phase_true_curvature_1hz),'omitnan');
        % 1 hz - Find first crossing of 0.2 bar via interpolation
        first_phase_half_idx = find(FP_p_1hz >= 0.20, 1, 'first');
        if ~isempty(first_phase_half_idx)
            first_phase_half_timing_1hz = t_s(first_phase_half_idx) - t_s(1); % double
        else
            first_phase_half_timing_1hz = NaN;
        end

        TestBrake(phaseIdx).First_phase_timing_half_1hz = first_phase_half_timing_1hz; % double
        TestBrake(phaseIdx).First_phase_half_time_ratio_1hz = first_phase_half_timing_1hz / max(eps, first_phase_timing_1hz);
        TestBrake(phaseIdx).First_phase_avg_rate_1hz = (cfg.EndBuildup - FP_p_1hz(1)) / max(eps, first_phase_timing_1hz);
        index_01 = find(FP_p_1hz <= 0.1, 1, 'last');
        if ~isempty(index_01) && index_01 >= 2
            dt01 = t_s(index_01) - t_s(1);     % numeric seconds (double)
            TestBrake(phaseIdx).First_phase_first_gradient_1hz = ...
                (FP_p_1hz(index_01) - FP_p_1hz(1)) / max(eps, dt01);
        else
            TestBrake(phaseIdx).First_phase_first_gradient_1hz = NaN;
        end

        TestBrake(phaseIdx).First_phase_max_gradient_1hz = max(first_phase_gradient_1hz);
        % --- Inflection point (first sign change of curvature) ---
        sc_1hz = find(diff(sign(first_phase_true_curvature_1hz)) ~= 0, 1, 'first');
        if ~isempty(sc_1hz)
            TestBrake(phaseIdx).First_phase_inflection_point_1hz = FP_t_1hz(sc_1hz);  % seconds from start
        else
            TestBrake(phaseIdx).First_phase_inflection_point_1hz = NaN;
        end
        % 1 hz
        first_phase_energy_1hz = trapz(t_s, FP_p_1hz);   % bar·s
        TestBrake(phaseIdx).First_phase_energy_1hz = first_phase_energy_1hz;
        TestBrake(phaseIdx).First_phase_power_1hz = first_phase_energy_1hz / max(eps, first_phase_timing_1hz);

    else 
        % 1 hz - No valid first phase (0.4 bar not reached)
        TestBrake(phaseIdx).End_first_phase_time_1hz      = NaT;
        TestBrake(phaseIdx).End_first_phase_pressure_1hz  = NaN;
        TestBrake(phaseIdx).First_phase_pressure_1hz      = [];
        TestBrake(phaseIdx).First_phase_time_1hz          = [];
        TestBrake(phaseIdx).First_phase_time_s_1hz        = [];    % store seconds axis
        TestBrake(phaseIdx).First_phase_timing_1hz        = NaN;
        TestBrake(phaseIdx).First_phase_gradient_1hz      = [];
        TestBrake(phaseIdx).First_phase_curvature_1hz     = [];
        TestBrake(phaseIdx).First_phase_curvNorm_1hz      = [];
        TestBrake(phaseIdx).First_phase_timing_half_1hz   = NaN;
        TestBrake(phaseIdx).First_phase_half_time_ratio_1hz = NaN;
        TestBrake(phaseIdx).First_phase_first_gradient_1hz = NaN;
        TestBrake(phaseIdx).First_phase_mean_curvature_1hz = NaN;
        TestBrake(phaseIdx).First_phase_max_gradient_1hz   = NaN;
        TestBrake(phaseIdx).First_phase_inflection_point_1hz = NaN;
        TestBrake(phaseIdx).First_phase_avg_rate_1hz = NaN;
        TestBrake(phaseIdx).First_phase_energy_1hz = NaN;
        TestBrake(phaseIdx).First_phase_power_1hz  = NaN;
    end

    if ~isempty(endFirstBuildupIdx) && endFirstBuildupIdx >= 2
        FP_p = buildup_pressure10hz_series(1:endFirstBuildupIdx);
        % FP_t = buildup_time_series(1:endFirstBuildupIdx);
        
        % 10 hz
        N  = numel(FP_p);
        n  = (0:N-1)'; % 0..N-1
        t  = n * dt; % seconds (synthetic, robust)
        t_dt = buildup_time_series(1:endFirstBuildupIdx);     % datetime
        % seconds-from-start (numeric)
        t_s = seconds(t_dt - t_dt(1));

        TestBrake(phaseIdx).First_phase_pressure   = FP_p;
        TestBrake(phaseIdx).First_phase_time       = t_dt;    % datetime
        TestBrake(phaseIdx).First_phase_time_s     = t_s;     % numeric seconds

        % FP_tD = FP_t;                    % datetime vector
        FP_t  = t(1:endFirstBuildupIdx); % seconds from phase start (synthetic)
        % timing (seconds)
        first_phase_timing = t_s(end) - t_s(1);
        TestBrake(phaseIdx).First_phase_timing = first_phase_timing;
        % --- Time/pressure at end of first phase (0.4 bar crossing) ---
        % first_phase_timing = seconds(FP_t(end) - FP_t(1));
        % 10 hz datetime interpolation assuming ~uniform sampling at Fs:
        % dtD  = seconds(FP_tD - FP_tD(1));
        % if dtD <= 0, dtD = dt; end
        TestBrake(phaseIdx).End_first_phase_time     = FP_t(end);
        TestBrake(phaseIdx).End_first_phase_pressure = FP_p(end);
        % --- First phase timing (seconds) ---
        TestBrake(phaseIdx).First_phase_timing = seconds(FP_t(end) - FP_t(1));
        % --- Derivatives and curvature (use uniform time for stability) ---
        % gradient dP/dt (bar/s)
        % 10 hz
        first_phase_gradient  = gradient(FP_p, t_s);
        first_phase_curvature = gradient(first_phase_gradient, t_s);
        first_phase_true_curvature = first_phase_curvature ./ (1 + first_phase_gradient.^2).^(3/2);    
        TestBrake(phaseIdx).First_phase_gradient   = first_phase_gradient;
        TestBrake(phaseIdx).First_phase_curvature  = first_phase_curvature;
        TestBrake(phaseIdx).First_phase_curvNorm   = first_phase_true_curvature;
        % --- Mean absolute normalized curvature ---
        TestBrake(phaseIdx).First_phase_mean_curvature = mean(abs(first_phase_true_curvature),'omitnan');

        % --- Half-time to 0.2 bar and ratio t_half / t_0.4 ---
        % 10 hz - Find first crossing of 0.2 bar via interpolation
        first_phase_half_idx = find(FP_p >= 0.20, 1, 'first');
        if ~isempty(first_phase_half_idx)
            first_phase_half_timing = t_s(first_phase_half_idx) - t_s(1);
        else
            first_phase_half_timing = NaN;
        end
        TestBrake(phaseIdx).First_phase_timing_half      = first_phase_half_timing;
        TestBrake(phaseIdx).First_phase_half_time_ratio  = first_phase_half_timing / max(eps, first_phase_timing);
        % --- Average rise rate over first phase (0 -> 0.4) ---
        TestBrake(phaseIdx).First_phase_avg_rate = (cfg.EndBuildup - FP_p(1)) / max(eps, first_phase_timing);

       % first gradient up to last sample <= 0.1 bar
       index_01 = find(FP_p <= 0.1, 1, 'last');
       if ~isempty(index_01) && index_01 >= 2
           TestBrake(phaseIdx).First_phase_first_gradient = ...
               (FP_p(index_01) - FP_p(1)) / max(eps, (t_s(index_01) - t_s(1)));
       else
           TestBrake(phaseIdx).First_phase_first_gradient = NaN;
       end

       TestBrake(phaseIdx).First_phase_max_gradient = max(first_phase_gradient);

       % inflection point (first sign change)
       sc = find(diff(sign(first_phase_true_curvature)) ~= 0, 1, 'first');
       if ~isempty(sc)
           TestBrake(phaseIdx).First_phase_inflection_point = t_s(sc);
       else
           TestBrake(phaseIdx).First_phase_inflection_point = NaN;
       end

       % energy + power
       first_phase_energy = trapz(t_s, FP_p);
       TestBrake(phaseIdx).First_phase_energy = first_phase_energy;
       TestBrake(phaseIdx).First_phase_power  = first_phase_energy / max(eps, first_phase_timing);
        

    else
        % 10 hz - No valid first phase (0.4 bar not reached)
        TestBrake(phaseIdx).End_first_phase_time      = NaT;
        TestBrake(phaseIdx).End_first_phase_pressure  = NaN;
        TestBrake(phaseIdx).First_phase_pressure      = [];
        TestBrake(phaseIdx).First_phase_time          = [];
        TestBrake(phaseIdx).First_phase_time_s        = [];     % numeric seconds
        TestBrake(phaseIdx).First_phase_timing        = NaN;
        TestBrake(phaseIdx).First_phase_gradient      = [];
        TestBrake(phaseIdx).First_phase_curvature     = [];
        TestBrake(phaseIdx).First_phase_curvNorm      = [];
        TestBrake(phaseIdx).First_phase_timing_half   = NaN;
        TestBrake(phaseIdx).First_phase_half_time_ratio = NaN;
        TestBrake(phaseIdx).First_phase_first_gradient = NaN;
        TestBrake(phaseIdx).First_phase_mean_curvature = NaN;
        TestBrake(phaseIdx).First_phase_max_gradient   = NaN;
        TestBrake(phaseIdx).First_phase_inflection_point = NaN;
        TestBrake(phaseIdx).First_phase_avg_rate = NaN;
        TestBrake(phaseIdx).First_phase_energy = NaN;
        TestBrake(phaseIdx).First_phase_power  = NaN;

    end

    %% -------- Write arrays & metrics (Brake / Buildup / Holding / Release) --------
    % Brake
    if ~isempty(brake_time_series)
        TestBrake(phaseIdx).Brake_time_cyl       = brake_time_series;
        TestBrake(phaseIdx).Brake_pressure_cyl   = brake_pressure_series;
        TestBrake(phaseIdx).Start_brake_time_cyl = brake_time_series(1);
        TestBrake(phaseIdx).End_brake_time_cyl   = brake_time_series(end);
        TestBrake(phaseIdx).Brake_timing_cyl     = seconds(brake_time_series(end) - brake_time_series(1));
        trel = seconds(brake_time_series - brake_time_series(1));
        if numel(trel) >= 2
            TestBrake(phaseIdx).Brake_energy_cyl = trapz(trel, brake_pressure_series);
        else
            TestBrake(phaseIdx).Brake_energy_cyl = NaN;
        end
        TestBrake(phaseIdx).Brake_power_cyl  = TestBrake(phaseIdx).Brake_energy_cyl / max(eps, TestBrake(phaseIdx).Brake_timing_cyl);
    else
        TestBrake(phaseIdx).Brake_time_cyl       = emptyDT;
        TestBrake(phaseIdx).Brake_pressure_cyl   = emptyDB;
        TestBrake(phaseIdx).Start_brake_time_cyl = NaT;
        TestBrake(phaseIdx).End_brake_time_cyl   = NaT;
        TestBrake(phaseIdx).Brake_timing_cyl     = NaN;
        TestBrake(phaseIdx).Brake_energy_cyl     = NaN;
        TestBrake(phaseIdx).Brake_power_cyl      = NaN;
    end

    % Buildup
    if ~isempty(endBuildupIdx)
        TestBrake(phaseIdx).Buildup_time_cyl     = buildup_time_series(1:endBuildupIdx);
        TestBrake(phaseIdx).Buildup_pressure_cyl = buildup_pressure_series(1:endBuildupIdx);
        TestBrake(phaseIdx).Buildup_timing_cyl   = seconds(TestBrake(phaseIdx).Buildup_time_cyl(end) - TestBrake(phaseIdx).Buildup_time_cyl(1));
        TestBrake(phaseIdx).Buildup_gradient_cyl = (TestBrake(phaseIdx).Buildup_pressure_cyl(end) - TestBrake(phaseIdx).Buildup_pressure_cyl(1)) / max(eps, TestBrake(phaseIdx).Buildup_timing_cyl);

        trel = seconds(TestBrake(phaseIdx).Buildup_time_cyl - TestBrake(phaseIdx).Buildup_time_cyl(1));
        if numel(trel) >= 2
            TestBrake(phaseIdx).Buildup_energy_cyl = trapz(trel, TestBrake(phaseIdx).Buildup_pressure_cyl);
        else
            TestBrake(phaseIdx).Buildup_energy_cyl = NaN;
        end
        TestBrake(phaseIdx).Buildup_power_cyl = TestBrake(phaseIdx).Buildup_energy_cyl / max(eps, TestBrake(phaseIdx).Buildup_timing_cyl);
        % ---- classify mode from Buildup timing (Emergency only) ----
        if EmergencyBraking
            tB = TestBrake(phaseIdx).Buildup_timing_cyl;
            if  tB >= 3.5 && tB <= 4.5        % P ≈ 4 ± 0.5 s
                TestBrake(phaseIdx).BrakeMode_Buildup = "P";
            elseif tB >= 21 && tB <= 27       % G ≈ 24 ± 3 s
                TestBrake(phaseIdx).BrakeMode_Buildup = "G";
            else
                TestBrake(phaseIdx).BrakeMode_Buildup = "unknown";
                DS_ErrorBuildup = true;       % out of window during Emergency
            end
        else
            TestBrake(phaseIdx).BrakeMode_Buildup = "unknown";
            % DS_ErrorBuildup stays false when not Emergency
        end

    else
        TestBrake(phaseIdx).Buildup_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Buildup_pressure_cyl = emptyDB;
        TestBrake(phaseIdx).Buildup_timing_cyl   = NaN;
        TestBrake(phaseIdx).Buildup_gradient_cyl = NaN;
        TestBrake(phaseIdx).Buildup_energy_cyl   = NaN;
        TestBrake(phaseIdx).Buildup_power_cyl    = NaN;
        if EmergencyBraking
            DS_ErrorBuildup = false; % cannot classify under Emergency if missing
        end
        TestBrake(phaseIdx).BrakeMode_Buildup = "unknown";
    end

    % Holding
    if ~isempty(endBuildupIdx) && ~isempty(brake_time_series)
        TestBrake(phaseIdx).Holding_time_cyl     = brake_time_series(endBuildupIdx:end);
        TestBrake(phaseIdx).Holding_pressure_cyl = brake_pressure_series(endBuildupIdx:end);
        TestBrake(phaseIdx).Holding_timing_cyl   = seconds(TestBrake(phaseIdx).Holding_time_cyl(end) - TestBrake(phaseIdx).Holding_time_cyl(1));

        trel = seconds(TestBrake(phaseIdx).Holding_time_cyl - TestBrake(phaseIdx).Holding_time_cyl(1));
        if numel(trel) >= 2
            TestBrake(phaseIdx).Holding_energy_cyl = trapz(trel, TestBrake(phaseIdx).Holding_pressure_cyl);
        else
            TestBrake(phaseIdx).Holding_energy_cyl = NaN;
        end
        TestBrake(phaseIdx).Holding_power_cyl = TestBrake(phaseIdx).Holding_energy_cyl / max(eps, TestBrake(phaseIdx).Holding_timing_cyl);
    else
        TestBrake(phaseIdx).Holding_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Holding_pressure_cyl = emptyDB;
        TestBrake(phaseIdx).Holding_timing_cyl   = NaN;
        TestBrake(phaseIdx).Holding_energy_cyl   = NaN;
        TestBrake(phaseIdx).Holding_power_cyl    = NaN;
    end

    % Release
    if ~isempty(release_time_series)
        cutIdx = find(release_pressure_series < cfg.EndPressure, 1, 'first');
        if ~isempty(cutIdx)
            release_time_series     = release_time_series(1:cutIdx);
            release_pressure_series = release_pressure_series(1:cutIdx);
        end

        TestBrake(phaseIdx).Release_time_cyl     = release_time_series;
        TestBrake(phaseIdx).Release_pressure_cyl = release_pressure_series;
        TestBrake(phaseIdx).Release_timing_cyl   = seconds(release_time_series(end) - release_time_series(1));

        trel = seconds(release_time_series - release_time_series(1));
        if numel(trel) >= 2
            TestBrake(phaseIdx).Release_energy_cyl = trapz(trel, release_pressure_series);
        else
            TestBrake(phaseIdx).Release_energy_cyl = NaN;
        end
        TestBrake(phaseIdx).Release_power_cyl    = TestBrake(phaseIdx).Release_energy_cyl / max(eps, TestBrake(phaseIdx).Release_timing_cyl);
        TestBrake(phaseIdx).Release_gradient_cyl = (release_pressure_series(end) - release_pressure_series(1)) / max(eps, TestBrake(phaseIdx).Release_timing_cyl);
        if EmergencyBraking
            tR = TestBrake(phaseIdx).Release_timing_cyl;
            if  tR >= 15.5 && tR <= 19.5       % P ≈ 17.5 ± 2 s
                TestBrake(phaseIdx).BrakeMode_Release = "P";
            elseif tR >= 46.5 && tR <= 58.5    % G ≈ 52.5 ± 6 s
                TestBrake(phaseIdx).BrakeMode_Release = "G";
            else
                TestBrake(phaseIdx).BrakeMode_Release = "unknown";
                DS_ErrorRelease = true;
            end
        else
            TestBrake(phaseIdx).BrakeMode_Release = "unknown";
        end
        
    elseif TestBrake(phaseIdx).Non_Standard_Braking == 1 % Code Update:
        p = brake_pressure_series(:);
        t = brake_time_series(:);

        [pmax, idxMax] = max(p);

        % Safety check: ensure we have samples after the peak
        if idxMax >= numel(p)
            % Peak is at the last sample - cannot extract release
            TestBrake(phaseIdx).Release_time_cyl     = emptyDT;
            TestBrake(phaseIdx).Release_pressure_cyl = emptyDB;
            TestBrake(phaseIdx).Release_timing_cyl   = NaN;
            TestBrake(phaseIdx).Release_energy_cyl   = NaN;
            TestBrake(phaseIdx).Release_power_cyl    = NaN;
            TestBrake(phaseIdx).Release_gradient_cyl = NaN;
            TestBrake(phaseIdx).BrakeMode_Release    = "unknown";

            % Skip the brake/holding trimming in this case
            continue;  % or handle appropriately
        end
        % Code Update: Define thresholds more robustly
        thr_start = pmax - 0.005;  % Start of release detection
        if pmax > 0.42
            thr_release = 0.4;
        else
            % For low pressure peaks, use a more conservative threshold
            thr_release = pmax*0.5;  % 40% of peak or 0.15, whichever is lower
        end
        % Find first index after peak where pressure drops below thr_start
        relativeIdx = find(p(idxMax+1:end) <= thr_start, 1, 'first');
        if isempty(relativeIdx)
            firstcutIdx = idxMax + 1;  % Start from sample after peak
        else
            firstcutIdx = idxMax + relativeIdx;
        end
        % Ensure firstcutIdx is valid
        if firstcutIdx > numel(p)
            firstcutIdx = numel(p);
        end
        % first crossing below thr_release AFTER the peak
        relLocal = find(p(firstcutIdx:end) <= thr_release, 1, 'first');
        if ~isempty(relLocal) && (firstcutIdx + relLocal - 1) > firstcutIdx
            endcutIdx = firstcutIdx + relLocal - 1;
            % slice
            release_time_series     = t(firstcutIdx:endcutIdx);
            release_pressure_series = p(firstcutIdx:endcutIdx);
            % compute metrics (unchanged)
            TestBrake(phaseIdx).Release_time_cyl   = release_time_series;
            TestBrake(phaseIdx).Release_pressure_cyl = release_pressure_series;
            TestBrake(phaseIdx).Release_timing_cyl = seconds(release_time_series(end) - release_time_series(1));
            trel = seconds(release_time_series - release_time_series(1));
            if numel(trel) >= 2
                TestBrake(phaseIdx).Release_energy_cyl = trapz(trel, release_pressure_series);
            else
                TestBrake(phaseIdx).Release_energy_cyl = NaN;
            end
            TestBrake(phaseIdx).Release_power_cyl    = TestBrake(phaseIdx).Release_energy_cyl / max(eps, TestBrake(phaseIdx).Release_timing_cyl);
            TestBrake(phaseIdx).Release_gradient_cyl = (release_pressure_series(end) - release_pressure_series(1)) / max(eps, TestBrake(phaseIdx).Release_timing_cyl);
            TestBrake(phaseIdx).BrakeMode_Release    = "unknown";

            % Map release start back to the brake arrays
            tRelStart = TestBrake(phaseIdx).Release_time_cyl(1);

            % Robust index match (works for datetime/duration/double)
            [~, relStartIdx_inBrake] = min(abs(brake_time_series - tRelStart));
            relStartIdx_inBrake = max(1, min(relStartIdx_inBrake, numel(brake_time_series)));
            % ------- Trim Brake to exclude release -------
            if relStartIdx_inBrake > 1
                brake_time_series_trim     = brake_time_series(1:relStartIdx_inBrake-1);
                brake_pressure_series_trim = brake_pressure_series(1:relStartIdx_inBrake-1);
            else
                brake_time_series_trim     = [];
                brake_pressure_series_trim = [];
            end
            % Write back + recompute Brake metrics
            if ~isempty(brake_time_series_trim)
                TestBrake(phaseIdx).Brake_time_cyl       = brake_time_series_trim;
                TestBrake(phaseIdx).Brake_pressure_cyl   = brake_pressure_series_trim;
                TestBrake(phaseIdx).Start_brake_time_cyl = brake_time_series_trim(1);
                TestBrake(phaseIdx).End_brake_time_cyl   = brake_time_series_trim(end);
                TestBrake(phaseIdx).Brake_timing_cyl     = seconds(brake_time_series_trim(end) - brake_time_series_trim(1));

                t0  = brake_time_series_trim(1);
                trel= seconds(brake_time_series_trim - t0);
                if numel(trel) >= 2
                    TestBrake(phaseIdx).Brake_energy_cyl = trapz(trel, brake_pressure_series_trim);
                else
                    TestBrake(phaseIdx).Brake_energy_cyl = NaN;
                end
                TestBrake(phaseIdx).Brake_power_cyl = TestBrake(phaseIdx).Brake_energy_cyl / max(eps, TestBrake(phaseIdx).Brake_timing_cyl);
            else
                % If trimming nukes the whole Brake, set empties
                TestBrake(phaseIdx).Brake_time_cyl       = emptyDT;
                TestBrake(phaseIdx).Brake_pressure_cyl   = emptyDB;
                TestBrake(phaseIdx).Start_brake_time_cyl = NaT;
                TestBrake(phaseIdx).End_brake_time_cyl   = NaT;
                TestBrake(phaseIdx).Brake_timing_cyl     = NaN;
                TestBrake(phaseIdx).Brake_energy_cyl     = NaN;
                TestBrake(phaseIdx).Brake_power_cyl      = NaN;
            end

            % ------- Trim Holding to end BEFORE release -------
            if ~isempty(endBuildupIdx) && ~isempty(brake_time_series)
                holdEndIdx = max(endBuildupIdx, min(relStartIdx_inBrake-1, numel(brake_time_series)));
                if holdEndIdx >= endBuildupIdx
                    TestBrake(phaseIdx).Holding_time_cyl     = brake_time_series(endBuildupIdx:holdEndIdx);
                    TestBrake(phaseIdx).Holding_pressure_cyl = brake_pressure_series(endBuildupIdx:holdEndIdx);

                    TestBrake(phaseIdx).Holding_timing_cyl = seconds( ...
                        TestBrake(phaseIdx).Holding_time_cyl(end) - TestBrake(phaseIdx).Holding_time_cyl(1));

                    t0h  = TestBrake(phaseIdx).Holding_time_cyl(1);
                    th   = seconds(TestBrake(phaseIdx).Holding_time_cyl - t0h);
                    if numel(th) >= 2
                        TestBrake(phaseIdx).Holding_energy_cyl = trapz(th, TestBrake(phaseIdx).Holding_pressure_cyl);
                    else
                        TestBrake(phaseIdx).Holding_energy_cyl = NaN;
                    end
                    TestBrake(phaseIdx).Holding_power_cyl = TestBrake(phaseIdx).Holding_energy_cyl / max(eps, TestBrake(phaseIdx).Holding_timing_cyl);
                else
                    % No space for holding after trimming
                    TestBrake(phaseIdx).Holding_time_cyl     = emptyDT;
                    TestBrake(phaseIdx).Holding_pressure_cyl = emptyDB;
                    TestBrake(phaseIdx).Holding_timing_cyl   = NaN;
                    TestBrake(phaseIdx).Holding_energy_cyl   = NaN;
                    TestBrake(phaseIdx).Holding_power_cyl    = NaN;
                end
            end
        else
            % fallback: no release detected
            TestBrake(phaseIdx).Release_time_cyl     = emptyDT;
            TestBrake(phaseIdx).Release_pressure_cyl = emptyDB;
            TestBrake(phaseIdx).Release_timing_cyl   = NaN;
            TestBrake(phaseIdx).Release_energy_cyl   = NaN;
            TestBrake(phaseIdx).Release_power_cyl    = NaN;
            TestBrake(phaseIdx).Release_gradient_cyl = NaN;
            TestBrake(phaseIdx).BrakeMode_Release    = "unknown";
        end
    else
        % fallback: no release detected
        TestBrake(phaseIdx).Release_time_cyl     = emptyDT;
        TestBrake(phaseIdx).Release_pressure_cyl = emptyDB;
        TestBrake(phaseIdx).Release_timing_cyl   = NaN;
        TestBrake(phaseIdx).Release_energy_cyl   = NaN;
        TestBrake(phaseIdx).Release_power_cyl    = NaN;
        TestBrake(phaseIdx).Release_gradient_cyl = NaN;
        TestBrake(phaseIdx).BrakeMode_Release    = "unknown";
    end

    % Summary stats/flags
    TestBrake(phaseIdx).Total_timing_cyl   = TestBrake(phaseIdx).Brake_timing_cyl +TestBrake(phaseIdx).Release_timing_cyl;
    TestBrake(phaseIdx).Total_energy_cyl   = TestBrake(phaseIdx).Brake_energy_cyl + TestBrake(phaseIdx).Release_energy_cyl;
    TestBrake(phaseIdx).Total_power_cyl    = TestBrake(phaseIdx).Total_energy_cyl/TestBrake(phaseIdx).Total_timing_cyl;

    % Combine DS_Error ONLY for EmergencyBrake phases
    if EmergencyBraking
        TestBrake(phaseIdx).DS_Error = uint8(DS_ErrorBuildup | DS_ErrorRelease);
    else
        TestBrake(phaseIdx).DS_Error = uint8(0);
    end
    bm = TestBrake(phaseIdx).BrakeMode_Buildup;
    if bm == "unknown"
        bm = TestBrake(phaseIdx).BrakeMode_Release;
    end
    TestBrake(phaseIdx).BrakeMode = bm;

    TestBrake(phaseIdx).Max_pressure_cyl        = maxPressure;
    TestBrake(phaseIdx).Brake_action_cyl        = double(maxPressure >= cfg.ActionThresh);

    meanP  = sumPressure / max(1, numSamples);
    varP   = max(0, sumPressureSq / max(1,numSamples) - meanP^2);
    TestBrake(phaseIdx).Mean_cyl                = meanP;
    TestBrake(phaseIdx).Std_cyl                 = sqrt(varP);
    TestBrake(phaseIdx).Consecutive_braking_cyl = consecutiveBrakingCount;
    % end


end
end
