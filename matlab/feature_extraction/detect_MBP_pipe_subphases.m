function TestBrake = detect_MBP_pipe_subphases(TestBrake, varargin)
% DETECT_MBP_PIPE_SUBPHASES
% Reimplements your reference "pipe" detector on each element of a 1xN TestBrake struct.
% Integrates using relative seconds (seconds(t - t(1))) and guards 1-sample windows.

% --------- parameters (match your reference; exposed for easy tuning) ----------
p = inputParser;
addParameter(p,'GradStart', -0.05); % default gradient < -0.05 -> buildup/braking
addParameter(p,'GradRelease',  0.05); % default gradient >  0.05 -> releasing
addParameter(p,'DistributorIdleThresh', 0.005); % default distributor < 0.1 -> back to idle
addParameter(p,'UseProvidedGradient', true);   % if MBP_Gradient exists, use it
addParameter(p,'SteadyReleaseGrad',   0.01);       % mild positive gradient for run detector [bar/s]
addParameter(p,'SteadyRelease',  40);          % consecutive samples required
addParameter(p,'ReleaseDrop_dP', 0.2);      % distributor drop [bar] within window
addParameter(p,'ReleaseDrop_WindowSec', 1.0);% seconds for distributor drop window
addParameter(p,'PressureSaturation', 1.5); % distributor saturation

parse(p,varargin{:});
cfg = p.Results;
% Unintended Brake Parameter
SV_Limit = 5.4;
UB_Limit = 0.4;
Psat = cfg.PressureSaturation;

% --- flatness counter config (change if needed) ---
flatGrad        = 0.005;   % |gradient| tolerance to consider "flat"
flatMaxCount    = 400;    % consecutive samples required to flip to 'braking'
flatCount       = 0;      % runtime counter (consecutive flat samples)
SteadyRelease   = 0;

for i = 1:numel(TestBrake)

    % Grab values (handle [], 0, or short vectors)
    p20_mbp = []; if isfield(TestBrake(i),'Post20s_MBP_Pressure'), p20_mbp = TestBrake(i).Post20s_MBP_Pressure; end
    p60_mbp = []; if isfield(TestBrake(i),'Post60s_MBP_Pressure'), p60_mbp = TestBrake(i).Post60s_MBP_Pressure; end
    p20_bc  = []; if isfield(TestBrake(i),'Post20s_BC_Pressure'),  p20_bc  = TestBrake(i).Post20s_BC_Pressure;  end
    p60_bc  = []; if isfield(TestBrake(i),'Post60s_BC_Pressure'),  p60_bc  = TestBrake(i).Post60s_BC_Pressure;  end

    flag20 = any(p20_mbp > SV_Limit) || any(p20_bc > UB_Limit);
    flag60 = any(p60_mbp > SV_Limit ) || any(p60_bc  > UB_Limit );
    flagUB = flag20 || flag60;
    TestBrake(i).UB_Error = logical(flagUB);

    % ---------- guards ----------
    if ~isfield(TestBrake(i),'MBP_Time') || ~isfield(TestBrake(i),'MBP_Pressure') ...
       || isempty(TestBrake(i).MBP_Time) || isempty(TestBrake(i).MBP_Pressure)
        TestBrake(i) = fill_empty_fields(TestBrake(i));
        continue
    end

    t = TestBrake(i).MBP_Time(:);
    p = TestBrake(i).MBP_Pressure(:);

    % sampling facts
    tsecs  = seconds(t - t(1));
    dt_vec = [max(eps, tsecs(2)-tsecs(1)); max(eps, diff(tsecs))];
    Fs     = 1/median(dt_vec);                       % Hz (approx)
    kDrop  = max(1, round(cfg.ReleaseDrop_WindowSec * Fs));  % samples in drop window

    % gradient source (follow your current choice)
    g = TestBrake(i).MBP_Gradient(:);

    % Distributor pressure as in reference
    distributor = p(1) - p;   % increases when MBP drops

    % ---------- state machine ----------
    timeBrakePipe       = datetime.empty(1,0);
    pressureBrakePipe   = double.empty(1,0);
    timeBuildupPipe     = datetime.empty(1,0);
    pressureBuildupPipe = double.empty(1,0);
    timeReleasePipe     = datetime.empty(1,0);
    pressureReleasePipe = double.empty(1,0);

    max_pressure_pipe    = 0;
    % brake_time_pipe      = 0;   % seconds
    release_time_pipe    = 0;   % seconds
    % brake_energy_pipe    = 0;
    % release_energy_pipe  = 0;
    sum_pressure_pipe    = 0;
    sum_pressure_sq_pipe = 0;
    num_samples_pipe     = 0;
    consecutive_braking  = 0;

    state = 'idle';
    segment_start_idx = 2;

    for c1 = 2:numel(t)-1
        time          = t(c1);
        gradient      = g(c1);
        distributor_p = distributor(c1);
        dt_s          = seconds(t(c1) - t(c1-1));
        if ~isfinite(dt_s) || dt_s<=0, dt_s = 0; end

        switch state
            case 'idle'
                if gradient < cfg.GradStart
                    state = 'buildup';
                    segment_start_idx = c1-1;
                end

            case 'buildup'
                t_seg = t(segment_start_idx:c1);
                p_seg = distributor(segment_start_idx:c1);
                
                distributor_p_sat = max(0, min(distributor_p, Psat));   % clamp to [0, Psat]

                timeBrakePipe       = [timeBrakePipe, time];
                pressureBrakePipe   = [pressureBrakePipe, distributor_p_sat];
                timeBuildupPipe     = [timeBuildupPipe, time];
                pressureBuildupPipe = [pressureBuildupPipe, distributor_p_sat];
                

                % brake_time_pipe = brake_time_pipe + dt_s;
                % if numel(t_seg) >= 2 && numel(p_seg) >= 2
                %     t_rel = seconds(t_seg - t_seg(1));
                %     p_seg_cap = min(p_seg, cfg.PressureSaturation);              % <-- cap
                %     brake_energy_pipe = brake_energy_pipe + trapz(t_rel, p_seg_cap);
                % end
                segment_start_idx = c1-1;

                if gradient >= cfg.SteadyReleaseGrad
                    SteadyRelease = SteadyRelease + 1;
                else
                    SteadyRelease = 0;
                end

                distributorDrop = false;
                if c1 > kDrop
                    dDrop = distributor(c1) - distributor(c1 - kDrop);  % negative if MBP rose
                    distributorDrop = (dDrop <= -cfg.ReleaseDrop_dP);
                end

                if gradient > cfg.GradRelease || SteadyRelease >= cfg.SteadyRelease || distributorDrop
                    state = 'releasing';
                    segment_start_idx = c1-1;
                    flatCount   = 0;
                    SteadyRelease = 0;
                end

            case 'braking'
                t_seg = t(segment_start_idx:c1);
                p_seg = distributor(segment_start_idx:c1);

                distributor_p_sat = max(0, min(distributor_p, Psat));   % clamp to [0, Psat]

                timeBrakePipe     = [timeBrakePipe, time];
                pressureBrakePipe = [pressureBrakePipe, distributor_p_sat];

                % brake_time_pipe = brake_time_pipe + dt_s;
                % if numel(t_seg) >= 2 && numel(p_seg) >= 2
                %     t_rel = seconds(t_seg - t_seg(1));
                %     p_seg_cap = min(p_seg, cfg.PressureSaturation);              % <-- cap
                %     brake_energy_pipe = brake_energy_pipe + trapz(t_rel, p_seg_cap);
                % end
                segment_start_idx = c1-1;

                if gradient >= cfg.SteadyReleaseGrad
                    SteadyRelease = SteadyRelease + 1;
                else
                    SteadyRelease = 0;
                end

                distributorDrop = false;
                if c1 > kDrop
                    dDrop = distributor(c1) - distributor(c1 - kDrop);
                    distributorDrop = (dDrop <= -cfg.ReleaseDrop_dP);
                end

                if gradient > cfg.GradRelease || distributorDrop || SteadyRelease >= cfg.SteadyRelease
                    state = 'releasing';
                    segment_start_idx = c1-1;
                    flatCount   = 0;
                    SteadyRelease = 0;
                end

            case 'releasing'
                t_seg = t(segment_start_idx:c1);
                p_seg = distributor(segment_start_idx:c1);
                distributor_p_sat = max(0, min(distributor_p, Psat));   % clamp to [0, Psat]

                timeReleasePipe     = [timeReleasePipe, time];
                pressureReleasePipe = [pressureReleasePipe, distributor_p_sat];

                % release_time_pipe = release_time_pipe + dt_s;
                % if numel(t_seg) >= 2 && numel(p_seg) >= 2
                %     t_rel = seconds(t_seg - t_seg(1));
                %     p_seg_cap = min(p_seg, cfg.PressureSaturation);              % <-- cap here too
                %     release_energy_pipe = release_energy_pipe + trapz(t_rel, p_seg_cap);
                % end
                segment_start_idx = c1-1;

                % --- NEW: if raw pressure still above saturation, bounce back to braking
                if distributor_p > Psat
                    % merge what we've collected in release back into brake
                    state = 'braking';
                    timeBrakePipe       = [timeBrakePipe,     timeReleasePipe];
                    pressureBrakePipe   = [pressureBrakePipe, pressureReleasePipe];

                    % reset release buffers
                    timeReleasePipe     = datetime.empty(1,0);
                    pressureReleasePipe = double.empty(1,0);

                    % bookkeeping
                    segment_start_idx   = c1-1;
                    flatCount = 0;

                    % proceed to next sample
                end
                
                if abs(gradient) <= flatGrad
                    flatCount = flatCount + 1;
                else
                    flatCount = 0;
                end

                

                if gradient < cfg.GradStart || flatCount >= flatMaxCount
                    state = 'braking';
                    timeBrakePipe        = [timeBrakePipe,     timeReleasePipe];
                    pressureBrakePipe    = [pressureBrakePipe, pressureReleasePipe];
                    % reset release
                    timeReleasePipe      = datetime.empty(1,0);
                    pressureReleasePipe  = double.empty(1,0);
                    % reset release
                    % release_time_pipe    = 0; % parity with reference
                    % release_energy_pipe  = 0;

                    % brake_time_pipe      = brake_time_pipe + release_time_pipe;
                    % brake_energy_pipe    = brake_energy_pipe + release_energy_pipe;
                    

                    segment_start_idx    = c1-1;
                    consecutive_braking  = consecutive_braking + 1;
                    flatCount = 0;

                elseif distributor_p < cfg.DistributorIdleThresh
                    state = 'idle';
                    segment_start_idx = c1-1;
                    flatCount = 0;
                end
        end

        if distributor_p > max_pressure_pipe
            max_pressure_pipe = distributor_p;
        end
        sum_pressure_pipe    = sum_pressure_pipe + distributor_p;
        sum_pressure_sq_pipe = sum_pressure_sq_pipe + distributor_p^2;
        num_samples_pipe     = num_samples_pipe + 1;
    end

    % ---------- split buildup vs holding with the 90% rule ----------
    Threshold_90_pipe = 0.9 * max(pressureBuildupPipe, [], 'omitnan');
    if isempty(Threshold_90_pipe) || ~isfinite(Threshold_90_pipe), Threshold_90_pipe = 0; end
    if ~isempty(pressureBuildupPipe)
        End_buildup_index_pipe = find(pressureBuildupPipe >= Threshold_90_pipe, 1, 'first');
    else
        End_buildup_index_pipe = [];
    end

    % ---------- write *_pipe arrays & scalars ----------
    % brake arrays
    if ~isempty(pressureBrakePipe) && ~isempty(timeBrakePipe)
        TestBrake(i).Brake_pressure_pipe  = pressureBrakePipe(:);
        TestBrake(i).Brake_time_pipe      = timeBrakePipe(:);
        TestBrake(i).Start_brake_pressure = pressureBrakePipe(1);
        TestBrake(i).Start_brake_time_pipe     = timeBrakePipe(1);
        TestBrake(i).End_brake_pressure   = pressureBrakePipe(end);
        TestBrake(i).End_brake_time_pipe       = timeBrakePipe(end);
        TestBrake(i).Brake_timing_pipe    = seconds(TestBrake(i).End_brake_time_pipe - TestBrake(i).Start_brake_time_pipe);
        if numel(TestBrake(i).Brake_time_pipe)>=2 && numel(TestBrake(i).Brake_pressure_pipe)>=2
            t_rel = seconds(TestBrake(i).Brake_time_pipe - TestBrake(i).Brake_time_pipe(1));
            p_cap = min(TestBrake(i).Brake_pressure_pipe, cfg.PressureSaturation); % saturation limit
            TestBrake(i).Brake_energy_pipe = trapz(t_rel, p_cap);
        else
            TestBrake(i).Brake_energy_pipe = 0;
        end
        % TestBrake(i).Brake_energy_pipe    = brake_energy_pipe;
        TestBrake(i).Brake_power_pipe     = TestBrake(i).Brake_energy_pipe / TestBrake(i).Brake_timing_pipe;
    else
        TestBrake(i).Brake_pressure_pipe  = [];
        TestBrake(i).Brake_time_pipe      = [];
        TestBrake(i).Start_brake_pressure = 0;
        TestBrake(i).Start_brake_time_pipe     = NaT;
        TestBrake(i).End_brake_pressure   = 0;
        TestBrake(i).End_brake_time_pipe       = NaT;
        TestBrake(i).Brake_timing_pipe    = 0;
        TestBrake(i).Brake_energy_pipe    = 0;
        TestBrake(i).Brake_power_pipe     = 0;
    end

    % buildup arrays
    if ~isempty(End_buildup_index_pipe)
        TestBrake(i).Buildup_pressure_pipe       = pressureBrakePipe(1:End_buildup_index_pipe).';
        TestBrake(i).Buildup_time_pipe           = timeBrakePipe(1:End_buildup_index_pipe).';
        TestBrake(i).Start_buildup_time_pipe     = TestBrake(i).Buildup_time_pipe(1);
        TestBrake(i).Start_buildup_pressure_pipe = TestBrake(i).Buildup_pressure_pipe(1);
        TestBrake(i).End_buildup_time_pipe       = TestBrake(i).Buildup_time_pipe(end);
        TestBrake(i).End_buildup_pressure_pipe   = TestBrake(i).Buildup_pressure_pipe(end);
        TestBrake(i).Buildup_timing_pipe         = seconds(TestBrake(i).End_buildup_time_pipe - TestBrake(i).Start_buildup_time_pipe);
        TestBrake(i).Buildup_gradient_pipe       = (TestBrake(i).End_buildup_pressure_pipe - TestBrake(i).Start_buildup_pressure_pipe) / TestBrake(i).Buildup_timing_pipe;
        if numel(TestBrake(i).Buildup_time_pipe)>=2 && numel(TestBrake(i).Buildup_pressure_pipe)>=2
            t_rel = seconds(TestBrake(i).Buildup_time_pipe - TestBrake(i).Buildup_time_pipe(1));
            p_cap = min(TestBrake(i).Buildup_pressure_pipe, cfg.PressureSaturation); % saturation limit
            TestBrake(i).Buildup_energy_pipe = trapz(t_rel, p_cap);
        else
            TestBrake(i).Buildup_energy_pipe = 0;
        end
        TestBrake(i).Buildup_power_pipe          = TestBrake(i).Buildup_energy_pipe / TestBrake(i).Buildup_timing_pipe;
    else
        TestBrake(i).Buildup_pressure_pipe = [];
        TestBrake(i).Buildup_time_pipe     = [];
        TestBrake(i).Start_buildup_time_pipe     = NaT;
        TestBrake(i).Start_buildup_pressure_pipe = 0;
        TestBrake(i).End_buildup_time_pipe       = NaT;
        TestBrake(i).End_buildup_pressure_pipe   = 0;
        TestBrake(i).Buildup_timing_pipe         = 0;
        TestBrake(i).Buildup_gradient_pipe       = 0;
        TestBrake(i).Buildup_energy_pipe         = 0;
        TestBrake(i).Buildup_power_pipe          = 0;
    end

    % holding arrays (only if we have buildup end and some brake data)
    if ~isempty(End_buildup_index_pipe) && ~isempty(pressureBrakePipe)
        TestBrake(i).Holding_time_pipe     = timeBrakePipe(End_buildup_index_pipe:end).';
        TestBrake(i).Holding_pressure_pipe = pressureBrakePipe(End_buildup_index_pipe:end).';
        TestBrake(i).Start_holding_time_pipe     = TestBrake(i).Holding_time_pipe(1);
        TestBrake(i).Start_holding_pressure_pipe = TestBrake(i).Holding_pressure_pipe(1);
        TestBrake(i).End_holding_time_pipe       = TestBrake(i).Holding_time_pipe(end);
        TestBrake(i).End_holding_pressure_pipe   = TestBrake(i).Holding_pressure_pipe(end);
        TestBrake(i).Holding_timing_pipe         = seconds(TestBrake(i).End_holding_time_pipe - TestBrake(i).Start_holding_time_pipe);
        if numel(TestBrake(i).Holding_time_pipe)>=2 && numel(TestBrake(i).Holding_pressure_pipe)>=2
            t_rel = seconds(TestBrake(i).Holding_time_pipe - TestBrake(i).Holding_time_pipe(1));
            p_cap = min(TestBrake(i).Holding_pressure_pipe, cfg.PressureSaturation); % saturation limit
            TestBrake(i).Holding_energy_pipe = trapz(t_rel, p_cap);
        else
            TestBrake(i).Holding_energy_pipe = 0;
        end
        TestBrake(i).Holding_power_pipe          = TestBrake(i).Holding_energy_pipe / TestBrake(i).Holding_timing_pipe;
    else
        TestBrake(i).Holding_time_pipe = [];
        TestBrake(i).Holding_pressure_pipe = [];
        TestBrake(i).Start_holding_time_pipe = NaT;
        TestBrake(i).Start_holding_pressure_pipe = 0;
        TestBrake(i).End_holding_time_pipe = NaT;
        TestBrake(i).End_holding_pressure_pipe = 0;
        TestBrake(i).Holding_timing_pipe = 0;
        TestBrake(i).Holding_energy_pipe = 0;
        TestBrake(i).Holding_power_pipe = 0;
    end

    % release arrays
    if ~isempty(timeReleasePipe) && ~isempty(pressureReleasePipe)
        TestBrake(i).Release_time_pipe     = timeReleasePipe(:);
        TestBrake(i).Release_pressure_pipe = pressureReleasePipe(:);
        TestBrake(i).Start_release_time_pipe     = timeReleasePipe(1);
        TestBrake(i).Start_release_pressure_pipe = pressureReleasePipe(1);
        TestBrake(i).End_release_time_pipe       = timeReleasePipe(end);
        TestBrake(i).End_release_pressure_pipe   = pressureReleasePipe(end);
        TestBrake(i).Release_timing_pipe         = seconds(TestBrake(i).End_release_time_pipe - TestBrake(i).Start_release_time_pipe);
        TestBrake(i).Release_gradient_pipe       = (TestBrake(i).End_release_pressure_pipe - TestBrake(i).Start_release_pressure_pipe) / TestBrake(i).Release_timing_pipe;
        if numel(TestBrake(i).Release_time_pipe)>=2 && numel(TestBrake(i).Release_pressure_pipe)>=2
            t_rel = seconds(TestBrake(i).Release_time_pipe - TestBrake(i).Release_time_pipe(1));
            p_cap = min(TestBrake(i).Release_pressure_pipe, cfg.PressureSaturation); % saturation limit
            TestBrake(i).Release_energy_pipe = trapz(t_rel, p_cap);
        else
            TestBrake(i).Release_energy_pipe = 0;
        end
        TestBrake(i).Release_power_pipe   = TestBrake(i).Release_energy_pipe / TestBrake(i).Release_timing_pipe;

    else
        TestBrake(i).Release_time_pipe     = [];
        TestBrake(i).Release_pressure_pipe = [];
        TestBrake(i).Start_release_time_pipe = NaT;
        TestBrake(i).Start_release_pressure_pipe = 0;
        TestBrake(i).End_release_time_pipe = NaT;
        TestBrake(i).End_release_pressure_pipe = 0;
        TestBrake(i).Release_timing_pipe   = 0;
        TestBrake(i).Release_gradient_pipe = 0;
        TestBrake(i).Release_energy_pipe   = 0;
        TestBrake(i).Release_power_pipe    = 0;
        TestBrake(i).Total_energy_pipe     = 0;
        TestBrake(i).Total_power_pipe      = 0;
    end

    % summary stats + flags

    TestBrake(i).Total_energy_pipe    = TestBrake(i).Brake_energy_pipe + TestBrake(i).Release_energy_pipe;
    TestBrake(i).Total_power_pipe     = TestBrake(i).Total_energy_pipe/(TestBrake(i).Brake_timing_pipe + TestBrake(i).Release_timing_pipe);

    TestBrake(i).Max_pressure_pipe   = max_pressure_pipe;
    TestBrake(i).EmergencyBrake_action  = double(TestBrake(i).Max_pressure_pipe >= 1.5);
    TestBrake(i).Mean_pipe           = sum_pressure_pipe / max(1,num_samples_pipe);
    TestBrake(i).Std_pipe            = sqrt( max(0, sum_pressure_sq_pipe/max(1,num_samples_pipe) - TestBrake(i).Mean_pipe^2) );
    if consecutive_braking >= 1
        TestBrake(i).Consecutive_braking_pipe = 1;
    else
        TestBrake(i).Consecutive_braking_pipe = 0;
    end
    

    % -------- Optional speed fields if present in this phase element --------
    if isfield(TestBrake(i),'GPS_Speed') && ~isempty(TestBrake(i).GPS_Speed)
        s  = TestBrake(i).GPS_Speed(:);
        tg = TestBrake(i).GPS_Time(:);
        TestBrake(i).Start_brake_speed = s(1);
        TestBrake(i).End_brake_speed   = s(end);
        TestBrake(i).Speed_difference  = s(end) - s(1);
        if numel(tg)>=2
            TestBrake(i).Speed_gradient = TestBrake(i).Speed_difference / seconds(tg(end)-tg(1));
        else
            TestBrake(i).Speed_gradient = 0;
        end
    else
        TestBrake(i).Start_brake_speed = 0;
        TestBrake(i).End_brake_speed   = 0;
        TestBrake(i).Speed_difference  = 0;
        TestBrake(i).Speed_gradient    = 0;
    end

    % -------- Gateway_VB_Error: count GPS_Vbatt readings < 10 V --------
    if isfield(TestBrake(i),'GPS_Vbatt') && ~isempty(TestBrake(i).GPS_Vbatt)
        vb = TestBrake(i).GPS_Vbatt(:);
        TestBrake(i).Gateway_VB_Error = sum(vb < 10 & ~isnan(vb));
    else
        TestBrake(i).Gateway_VB_Error = 0;
    end

    % -------- Gateway_CB_Error: count occurrences of value == 308 in GPS_RPM_axle --------
    if isfield(TestBrake(i),'GPS_RPM_axle') && ~isempty(TestBrake(i).GPS_RPM_axle)
        rpm = TestBrake(i).GPS_RPM_axle(:);
        TestBrake(i).Gateway_CB_Error = sum(rpm == 308);
    else
        TestBrake(i).Gateway_CB_Error = 0;
    end

end
end

% ---------------- helper to fill empty outputs ----------------
function S = fill_empty_fields(S)
S.Brake_pressure_pipe = []; S.Brake_time_pipe = [];
S.Start_brake_pressure = 0; S.Start_brake_time_pipe = NaT;
S.End_brake_pressure = 0;   S.End_brake_time_pipe = NaT;
S.Brake_timing_pipe = 0; S.Brake_energy_pipe = 0; S.Brake_power_pipe = 0;


S.Buildup_pressure_pipe = []; S.Buildup_time_pipe = [];
S.Start_buildup_time_pipe = NaT; S.Start_buildup_pressure_pipe = 0;
S.End_buildup_time_pipe = NaT;   S.End_buildup_pressure_pipe = 0;
S.Buildup_timing_pipe = 0; S.Buildup_gradient_pipe = 0;
S.Buildup_energy_pipe = 0; S.Buildup_power_pipe = 0;

S.Holding_time_pipe = []; S.Holding_pressure_pipe = [];
S.Start_holding_time_pipe = NaT; S.Start_holding_pressure_pipe = 0;
S.End_holding_time_pipe = NaT;   S.End_holding_pressure_pipe = 0;
S.Holding_timing_pipe = 0; S.Holding_energy_pipe = 0; S.Holding_power_pipe = 0;

S.Release_time_pipe = []; S.Release_pressure_pipe = [];
S.Start_release_time_pipe = NaT; S.Start_release_pressure_pipe = 0;
S.End_release_time_pipe = NaT;   S.End_release_pressure_pipe = 0;
S.Release_timing_pipe = 0; S.Release_gradient_pipe = 0;
S.Release_energy_pipe = 0; S.Release_power_pipe = 0;

S.Max_pressure_pipe = 0; S.EmergencyBrake_action = 0;
S.Mean_pipe = 0; S.Std_pipe = 0; S.Consecutive_braking_pipe = 0;
S.Total_power_pipe = 0;
S.Total_energy_pipe = 0;

S.MBP_Mask_BuildupPipe = false(0,1);
S.MBP_Mask_HoldingPipe = false(0,1);
S.MBP_Mask_ReleasePipe = false(0,1);
end
