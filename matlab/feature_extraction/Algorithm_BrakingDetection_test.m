function [TestBrake, bc_row_indices, wv_row_indices] = Algorithm_BrakingDetection_test(Test, windowSize, verbose)
% DETECT_MBP_BC_WV_TO_STRUCT
% CHECKPOINT: 2025-10-06  |  Refined names + comments  |  GPS + per-sensor Vbatt/Temperature/RSSI
%
% Purpose:
%   Detect braking phases on the MBP signal and attach synchronized data:
%     - MBP (time, pressure, gradient) + MBP_Vbatt/MBP_Temperature/MBP_RSSI (sliced by phase)
%     - BC(r) streams (time, pressure, gradient) + Vbatt/Temperature/RSSI (streamed, post-extend)
%     - WV(r) slices (time, pressure) + Vbatt/Temperature/RSSI (sliced by phase)
%     - GPS_* fields sliced and appended directly to each TestBrake(k)
%
% Inputs:
%   Test        : struct array of channels (each with Label and fields)
%   windowSize  : moving window length (samples) for MBP stability (default 80)
%   verbose     : print progress (default true)
%
% Outputs:
%   TestBrake       : per-phase struct with MBP + BC[] + WV[] (+ GPS_* fields)
%   bc_row_indices  : indices of BC channels in Test
%   wv_row_indices  : indices of WV channels in Test
%
% Notes:
%   - WV & GPS are sliced within [MBP start, MBP end]; BC streams can extend a bit post-MBP.
%   - If MBP SV_Error at onset, BC and WV are filled with SensorError placeholders.
%   - Any WV window with <2 samples → WV_SensorError=true.
%   - Telemetry vectors with different lengths are aligned and padded with NaN safely.

if nargin < 2, windowSize = 80; end
if nargin < 3, verbose = true; end

%% -------------------------------------------------------------------------
%% 1) Locate channels by label
%% -------------------------------------------------------------------------
mbp_row_index = [];
for chanIdx = 1:numel(Test)
    if isfield(Test(chanIdx),'Label') && strcmpi(strtrim(string(Test(chanIdx).Label)), 'MBP')
        mbp_row_index = chanIdx; break
    end
end
if isempty(mbp_row_index), error('No MBP channel found.'); end

bc_row_indices = [];  % BC = brake cylinder channels
wv_row_indices = [];  % WV = wheel valve channels
for chanIdx = 1:numel(Test)
    if isfield(Test(chanIdx),'Label')
        labelUppercase = upper(strtrim(string(Test(chanIdx).Label)));
        if startsWith(labelUppercase,"BC"), bc_row_indices(end+1) = chanIdx; end %#ok<AGROW>
        if startsWith(labelUppercase,"WV"), wv_row_indices(end+1) = chanIdx; end %#ok<AGROW>
    end
end
numBC = numel(bc_row_indices);
numWV = numel(wv_row_indices);

%% -------------------------------------------------------------------------
%% 2) MBP core signals — TIME / PRESSURE / GRADIENT (baseline grid)
%%    >>> IMPORTANT: time vector, pressure vector, and gradient for MBP <<<
%% -------------------------------------------------------------------------
% TIME (MBP)
mbp_time = Test(mbp_row_index).Time(:);

mbp_is_datetime = isdatetime(mbp_time);
if mbp_is_datetime
    mbp_t0       = mbp_time(1);
    mbp_time_sec = seconds(mbp_time - mbp_t0);   % numeric seconds relative to MBP t0
else
    mbp_time_sec = mbp_time;
    mbp_t0       = 0;
end


% PRESSURE (MBP)
mbp_pressure = Test(mbp_row_index).Pressure_filter;
mbp_pressure10hz = Test(mbp_row_index).Pressure_filter_10Hz(:);


% GRADIENT (MBP)
mbp_gradient = Test(mbp_row_index).Gradient_pressure_filtered(:);

% Per-sensor telemetry (MBP) — may be shorter than time; align & pad later
mbp_vbatt_raw       = []; if isfield(Test(mbp_row_index),'Vbatt'),       mbp_vbatt_raw       = Test(mbp_row_index).Vbatt(:);       end
mbp_temp_raw        = []; if isfield(Test(mbp_row_index),'Temperature'), mbp_temp_raw        = Test(mbp_row_index).Temperature(:); end
mbp_rssi_raw        = []; if isfield(Test(mbp_row_index),'RSSI'),        mbp_rssi_raw        = Test(mbp_row_index).RSSI(:);        end

mbp_id    = []; if isfield(Test(mbp_row_index),'ID'), mbp_id = Test(mbp_row_index).ID; end
mbp_label = string(Test(mbp_row_index).Label);

% Keep first occurrence of each time (stable), and align arrays to match.
[mbp_time_sec_u, ia] = unique(mbp_time_sec, 'stable');

if numel(mbp_time_sec_u) < numel(mbp_time_sec)
    % Reduce the MBP vectors to the unique time base
    if mbp_is_datetime
        mbp_time = mbp_time(ia);
    end
    % Guard against any rare length mismatches
    if numel(mbp_pressure) >= max(ia)
        mbp_pressure = mbp_pressure(ia);
        mbp_pressure10hz = mbp_pressure10hz(ia);
    else
        % Defensive: trim ia to available pressure length
        iaP = ia(ia <= numel(mbp_pressure));
        mbp_pressure = mbp_pressure(iaP);
        mbp_pressure10hz= mbp_pressure10hz(iaP);
        mbp_time_sec_u = mbp_time_sec_u(1:numel(iaP));
        if mbp_is_datetime, mbp_time = mbp_time(1:numel(iaP)); end
    end
    if numel(mbp_gradient) >= max(ia)
        mbp_gradient = mbp_gradient(ia);
    else
        iaG = ia(ia <= numel(mbp_gradient));
        mbp_gradient = mbp_gradient(iaG);
        % Keep lengths consistent (already constrained above)
    end

    mbp_time_sec = mbp_time_sec_u;  % commit unique time base
end

numMBPSamples  = numel(mbp_time);

% Helper to pad any vector to a specific length with NaN
padToLength = @(x,n) [x(1:min(numel(x),n)); nan(max(0,n-numel(x)),1)];

% Align MBP telemetry to MBP time length, then we slice per phase by index
mbp_vbatt_aligned       = padToLength(mbp_vbatt_raw,       numMBPSamples);
mbp_temp_aligned        = padToLength(mbp_temp_raw,        numMBPSamples);
mbp_rssi_aligned        = padToLength(mbp_rssi_raw,        numMBPSamples);

if verbose
    fprintf('[detect_MBP_BC_WV_to_struct] Scanning %d MBP samples (%s)\n', numMBPSamples, char(mbp_label));
    fprintf('  Found %d BC channels, %d WV channels.\n', numBC, numWV);
end

%% -------------------------------------------------------------------------
%% 3) Build BC streams (time / pressure / gradient + telemetry, aligned)
%%    >>> IMPORTANT: BC time alignment to MBP t0; pad telemetry <<<
%% -------------------------------------------------------------------------
BC = repmat(struct( ...
    'testIndex', NaN, ...
    'label', "", ...
    'id', [], ...
    'time', [], ...
    'time_sec', [], ...
    'pressure', [], ...
    'pressure10hz', [], ...
    'gradient', [], ...
    'Vbatt', [], ...
    'Temperature', [], ...
    'RSSI', [], ...
    'idx_pointer', 1), numBC, 1);

for bcIdx = 1:numBC
    rowIndex            = bc_row_indices(bcIdx);
    BC(bcIdx).testIndex = rowIndex;
    BC(bcIdx).label     = string(Test(rowIndex).Label);
    if isfield(Test(rowIndex),'ID'), BC(bcIdx).id = Test(rowIndex).ID; end
    
    BC(bcIdx).time = Test(rowIndex).Time(:);


    if isdatetime(BC(bcIdx).time), BC(bcIdx).time_sec = seconds(BC(bcIdx).time - mbp_t0);
    else,                          BC(bcIdx).time_sec = BC(bcIdx).time; end

    % Deduplicate timestamps (stable) and remember mapping
    [BC(bcIdx).time_sec, uniqueIdx] = unique(BC(bcIdx).time_sec,'stable');
    if isdatetime(BC(bcIdx).time), BC(bcIdx).time = BC(bcIdx).time(uniqueIdx); end
    numTimeSamples = numel(BC(bcIdx).time_sec);

    % PRESSURE (BC) aligned to uniqueIdx and padded
    pressureRaw = Test(rowIndex).Pressure_filter(:);
    mapP = uniqueIdx(uniqueIdx <= numel(pressureRaw));
    pressureAligned = nan(numTimeSamples,1);
    pressureAligned(1:numel(mapP)) = pressureRaw(mapP);

    % PRESSURE (BC) 10 hz
    pressureRaw10hz = Test(rowIndex).Pressure_filter_10Hz(:);
    mapP10hz = uniqueIdx(uniqueIdx <= numel(pressureRaw10hz));
    pressure10hzAligned = nan(numTimeSamples,1);
    pressure10hzAligned(1:numel(mapP)) = pressureRaw10hz(mapP);

    % GRADIENT (BC) 1 hz
    gradRaw = Test(rowIndex).Gradient_pressure_filtered(:);
    mapG = uniqueIdx(uniqueIdx <= numel(gradRaw));
    gradientAligned = nan(numTimeSamples,1);
    gradientAligned(1:numel(mapG)) = gradRaw(mapG);

    % TELEMETRY (BC) — align to uniqueIdx, pad with NaN
    vbattRaw = []; if isfield(Test(rowIndex),'Vbatt'),       vbattRaw = Test(rowIndex).Vbatt(:);       end
    tempRaw  = []; if isfield(Test(rowIndex),'Temperature'), tempRaw  = Test(rowIndex).Temperature(:); end
    rssiRaw  = []; if isfield(Test(rowIndex),'RSSI'),        rssiRaw  = Test(rowIndex).RSSI(:);        end

    vbattAligned = nan(numTimeSamples,1);
    tempAligned  = nan(numTimeSamples,1);
    rssiAligned  = nan(numTimeSamples,1);
    if ~isempty(vbattRaw)
        mapV = uniqueIdx(uniqueIdx <= numel(vbattRaw));
        vbattAligned(1:numel(mapV)) = vbattRaw(mapV);
    end
    if ~isempty(tempRaw)
        mapT = uniqueIdx(uniqueIdx <= numel(tempRaw));
        tempAligned(1:numel(mapT)) = tempRaw(mapT);
    end
    if ~isempty(rssiRaw)
        mapR = uniqueIdx(uniqueIdx <= numel(rssiRaw));
        rssiAligned(1:numel(mapR)) = rssiRaw(mapR);
    end

    % Store aligned BC streams (idx_pointer walks this length)
    BC(bcIdx).pressure    = pressureAligned;
    BC(bcIdx).pressure10hz= pressure10hzAligned;
    BC(bcIdx).gradient    = gradientAligned;
    BC(bcIdx).Vbatt       = vbattAligned;
    BC(bcIdx).Temperature = tempAligned;
    BC(bcIdx).RSSI        = rssiAligned;
    BC(bcIdx).idx_pointer      = 1;
end

%% -------------------------------------------------------------------------
%% 4) Build WV static slices (time / pressure + telemetry, aligned)
%%    >>> IMPORTANT: WV uses slicing inside each MBP window, no streaming <<<
%% -------------------------------------------------------------------------
WV = repmat(struct( ...
    'testIndex', NaN, ...
    'label', "", ...
    'id', [], ...
    'time', [], ...
    'time_sec', [], ...
    'pressure', [], ...
    'Vbatt', [], ...
    'Temperature', [], ...
    'RSSI', []), numWV, 1);

for wvIdx = 1:numWV
    rowIndex            = wv_row_indices(wvIdx);
    WV(wvIdx).testIndex = rowIndex;
    WV(wvIdx).label     = string(Test(rowIndex).Label);
    if isfield(Test(rowIndex),'ID'), WV(wvIdx).id = Test(rowIndex).ID; end

    % TIME (WV)
    WV(wvIdx).time = Test(rowIndex).Time(:);

    if isdatetime(WV(wvIdx).time), WV(wvIdx).time_sec = seconds(WV(wvIdx).time - mbp_t0);
    else,                           WV(wvIdx).time_sec = WV(wvIdx).time; end

    [WV(wvIdx).time_sec, uniqueIdx] = unique(WV(wvIdx).time_sec,'stable');
    if isdatetime(WV(wvIdx).time),  WV(wvIdx).time = WV(wvIdx).time(uniqueIdx); end
    numTimeSamples = numel(WV(wvIdx).time_sec);

    % PRESSURE (WV)
    pressureRaw = Test(rowIndex).Pressure_filter(:);
    mapP = uniqueIdx(uniqueIdx <= numel(pressureRaw));
    pressureAligned = nan(numTimeSamples,1);
    pressureAligned(1:numel(mapP)) = pressureRaw(mapP);

    % TELEMETRY (WV) — align to uniqueIdx, pad with NaN
    vbattRaw = []; if isfield(Test(rowIndex),'Vbatt'),       vbattRaw = Test(rowIndex).Vbatt(:);       end
    tempRaw  = []; if isfield(Test(rowIndex),'Temperature'), tempRaw  = Test(rowIndex).Temperature(:); end
    rssiRaw  = []; if isfield(Test(rowIndex),'RSSI'),        rssiRaw  = Test(rowIndex).RSSI(:);        end

    vbattAligned = nan(numTimeSamples,1);
    tempAligned  = nan(numTimeSamples,1);
    rssiAligned  = nan(numTimeSamples,1);
    if ~isempty(vbattRaw)
        mapV = uniqueIdx(uniqueIdx <= numel(vbattRaw));
        vbattAligned(1:numel(mapV)) = vbattRaw(mapV);
    end
    if ~isempty(tempRaw)
        mapT = uniqueIdx(uniqueIdx <= numel(tempRaw));
        tempAligned(1:numel(mapT)) = tempRaw(mapT);
    end
    if ~isempty(rssiRaw)
        mapR = uniqueIdx(uniqueIdx <= numel(rssiRaw));
        rssiAligned(1:numel(mapR)) = rssiRaw(mapR);
    end

    WV(wvIdx).pressure    = pressureAligned;
    WV(wvIdx).Vbatt       = vbattAligned;
    WV(wvIdx).Temperature = tempAligned;
    WV(wvIdx).RSSI        = rssiAligned;
end

%% -------------------------------------------------------------------------
%% 5) GPS (shared across sensors) — build once and slice per phase
%%    >>> GPS is appended flat to TestBrake(k) with GPS_* names <<<
%% -------------------------------------------------------------------------
gps_row_index = [];
if isfield(Test(mbp_row_index), 'Time_GPS')
    gps_row_index = mbp_row_index;
else
    for chanIdx = 1:numel(Test)
        if isfield(Test(chanIdx), 'Time_GPS'), gps_row_index = chanIdx; break; end
    end
end

GPS = struct('hasData', false);
if ~isempty(gps_row_index) && isfield(Test(gps_row_index),'Time_GPS') && isdatetime(Test(gps_row_index).Time_GPS)
    gps_time     = Test(gps_row_index).Time_GPS(:);
    gps_time_sec = seconds(gps_time - mbp_t0);
    [gps_time_sec, gpsUniqueIdx] = unique(gps_time_sec, 'stable');
    gps_time = gps_time(gpsUniqueIdx);

    toColumn = @(x) reshape(x(:), [], 1);
    gps_long      = []; if isfield(Test(gps_row_index),'Long'),      gps_long      = toColumn(Test(gps_row_index).Long);      end
    gps_lat       = []; if isfield(Test(gps_row_index),'Lat'),       gps_lat       = toColumn(Test(gps_row_index).Lat);       end
    gps_speed     = []; if isfield(Test(gps_row_index),'Speed'),     gps_speed     = toColumn(Test(gps_row_index).Speed);     end
    gps_speed_rpm = []; if isfield(Test(gps_row_index),'Speed_RPM'), gps_speed_rpm = toColumn(Test(gps_row_index).Speed_RPM); end
    gps_ibatt     = []; if isfield(Test(gps_row_index),'GPS_Ibatt'), gps_ibatt     = toColumn(Test(gps_row_index).GPS_Ibatt); end
    gps_vbatt     = []; if isfield(Test(gps_row_index),'GPS_Vbatt'), gps_vbatt     = toColumn(Test(gps_row_index).GPS_Vbatt); end
    gps_rpm_axle  = []; if isfield(Test(gps_row_index),'RPM_axle'),  gps_rpm_axle  = toColumn(Test(gps_row_index).RPM_axle);  end

    if ~isempty(gps_long),      gps_long      = gps_long(gpsUniqueIdx);      end
    if ~isempty(gps_lat),       gps_lat       = gps_lat(gpsUniqueIdx);       end
    if ~isempty(gps_speed),     gps_speed     = gps_speed(gpsUniqueIdx);     end
    if ~isempty(gps_speed_rpm), gps_speed_rpm = gps_speed_rpm(gpsUniqueIdx); end
    if ~isempty(gps_ibatt),     gps_ibatt     = gps_ibatt(gpsUniqueIdx);     end
    if ~isempty(gps_vbatt),     gps_vbatt     = gps_vbatt(gpsUniqueIdx);     end
    if ~isempty(gps_rpm_axle),  gps_rpm_axle  = gps_rpm_axle(gpsUniqueIdx);  end

    GPS.hasData   = true;
    GPS.time      = gps_time;
    GPS.time_sec  = gps_time_sec;
    GPS.Long      = gps_long;
    GPS.Lat       = gps_lat;
    GPS.Speed     = gps_speed;
    GPS.Speed_RPM = gps_speed_rpm;
    GPS.GPS_Ibatt = gps_ibatt;
    GPS.GPS_Vbatt = gps_vbatt;
    GPS.RPM_axle  = gps_rpm_axle;
end

%% -------------------------------------------------------------------------
%% 6) Detection parameters
%% -------------------------------------------------------------------------
% Code Update increse MBP upper limit to 5.2
MBP_Lower=4.7; MBP_Upper=5.2; 
GradZeroTol=0.02; 
StableFrac=0.6;
StablePointCount = max(1, ceil(StableFrac * min(windowSize, numMBPSamples)));
InitGrad_Thresh=-0.05; 
% Code Update reduce P_Release to increase consecutive braking
P_Release=0.05; 
% Code Update increase Min_P_drop from reference transfer function to 0.2
Min_P_drop=0.2;
EmergencyBraking=1.50; 
GradEndThresh=0.00;
GradientStableThreshold=0.02; 
controlWindow_Delay_sec=2; ControlWindow_ActiveMax_sec=4;

SV_EndStableHold_s = 5;   % if skipBC_due_to_SV==true: end when |grad|<0.02 for >=5s

BC_BuildupEnd         = 0.6; % bar
BC_EndThreshold       = 0.40;     % bar
WV_fluctuation        = 0.2; % bar
BC_BuildupPhase_P     = 0.4; % bar
BC_EndWinSamples      = 80;       % window length to judge "mostly-down"
BC_EndMostlyDownFrac  = 0.60;     % >70% negative gradients in the window
BC_ExtendAfterMBP_s   = 10;       % extend at most X seconds past MBP end

%% -------------------------------------------------------------------------
%% 7) State (per-scan and per-phase)
%% -------------------------------------------------------------------------
inBraking=false; initPressure=NaN;
mbp_time_buffer=[]; 
mbp_pressure_buffer=[]; 
mbp_pressure10hz_buffer=[];
mbp_gradient_buffer=[];
phaseStartIdx=NaN; phaseStartTime=[]; phaseStartTime_sec=NaN;

TestBrake = struct([]);     
numPhases = 0;

% MBP guard
samplesSinceDrop=0; controlWindowCheck=false; controlWindow=false;
controlWindow_startTime=[]; controlWindow_startTime_sec=NaN; controlWindow_Fluctuation=false;
ControlWindow_StopMax_sec = 1800;   % 1 hour hard cap for a single MBP phase

% SV early-end (only when skipBC_due_to_SV is true)
sv_hold_active     = false;
sv_hold_start_sec  = NaN;

% BC per-phase stream buffers
bc_isActive                = false(numBC,1);
bc_time_buffer             = cell(numBC,1);
bc_time_buffer_sec         = cell(numBC,1);
bc_pressure_buffer         = cell(numBC,1);
bc_pressure10hz_buffer     = cell(numBC,1);
bc_gradient_buffer         = cell(numBC,1);
bc_vbatt_buffer            = cell(numBC,1);
bc_temp_buffer             = cell(numBC,1);
bc_rssi_buffer             = cell(numBC,1);
bc_BrakingNormal_flag      = false(numBC,1);
bc_sensor_error_flag       = false(numBC,1);
bc_badstart                = false(numBC,1);
bc_LowBraking              = false(numBC,1);
bc_marked_end_flag         = false(numBC,1);
skipBC_due_to_SV           = false;
skipWV_due_to_SV           = false;
closingPhase               = false;
% Code Update: variable to account for different sensor error
bc_start_above_thresh      = false(numBC,1);
bc_flat_start_near_zero    = false(numBC,1);
bc_already_engaged_flag    = false(numBC,1);
bc_releasing_at_start_flag = false(numBC,1);
bc_flat_checked            = false(numBC,1);

post20_active = false;
post20_tcap   = NaN;
post20_phaseIdx = NaN;

post60_active = false;
post60_tcap   = NaN;
post60_phaseIdx = NaN;

% independent cursors for post capture (per BC)
post20_bc_ptr = ones(numBC,1);
post60_bc_ptr = ones(numBC,1);


%% 8 
%
for k = 1:numMBPSamples

    t_now_sec = mbp_time_sec(k);

    % ==========================================================
    % 1) If MBP is ACTIVE: normal streaming (same as now)
    % ==========================================================
    if inBraking
        % (A) Append MBP buffers up to current k (same as now)
        % Accumulate MBP into phase buffers
        mbp_time_buffer(end+1,1)     = mbp_time(k);
        mbp_pressure_buffer(end+1,1) = mbp_pressure(k);
        mbp_pressure10hz_buffer(end+1,1) = mbp_pressure10hz(k);
        mbp_gradient_buffer(end+1,1) = mbp_gradient(k);
        forceEnd_SV = false;
        % Control Window logic
        samplesSinceDrop  = samplesSinceDrop + 1;
        seconds_postDrop  = mbp_time_sec(k) - phaseStartTime_sec;

        % If a single MBP braking phase lasts more than 1 hour, end it (System down/Train fullstop).
        if ~SystemStopped && (seconds_postDrop >= ControlWindow_StopMax_sec)
            SystemStopped  = true; % will be used by the end condition below
            if verbose
                fprintf('  [Phase %d] Long-stop guard: %.1f s >= %.0f s → FORCE END (SystemStopped)\n', ...
                    numPhases+1, seconds_postDrop, ControlWindow_StopMax_sec);
            end
            % Discard collected buffers
            inBraking = false;
            initPressure = NaN;
            mbp_time_buffer = [];
            mbp_pressure_buffer = [];
            mbp_pressure10hz_buffer = [];
            mbp_gradient_buffer = [];
            phaseStartIdx = NaN;
            phaseStartTime = [];
            phaseStartTime_sec = NaN;
            samplesSinceDrop = 0;
            controlWindowCheck = false;
            controlWindow = false;
            controlWindow_startTime = [];
            controlWindow_startTime_sec = NaN;
            controlWindow_Fluctuation = false;
            continue;  % skip saving

        end
        if ~controlWindowCheck && (seconds_postDrop >= controlWindow_Delay_sec)
            controlWindowCheck           = true;
            controlWindow                = true;
            controlWindow_startTime      = mbp_time(k);
            controlWindow_startTime_sec  = mbp_time_sec(k);
            controlWindow_Fluctuation = false;
            if verbose
                fprintf('  [Phase %d] ControlWindow ON at t=%.3fs (+%.1fs from start)\n', ...
                    numPhases+1, t_now_sec, seconds_postDrop);
            end


        end
        if controlWindow
            if mbp_gradient(k) < 0
                controlWindow_Fluctuation = true;
                controlWindow = false;
                if verbose
                    fprintf('  [Phase %d] ControlWindow OFF (fluctuation): G=%.4f at t=%.3fs\n', ...
                        numPhases+1, mbp_gradient(k), t_now_sec);
                end

            else
                if (mbp_time_sec(k) - controlWindow_startTime_sec) >= ControlWindow_ActiveMax_sec && ~controlWindow_Fluctuation
                    if verbose
                        fprintf('  [Phase %d] DISCARD by ControlWindow: stable for %.1fs (ActiveMax=%.1fs)\n', ...
                            numPhases+1, (mbp_time_sec(k)-controlWindow_startTime_sec), ControlWindow_ActiveMax_sec);
                    end

                    inBraking=false; initPressure=NaN;
                    mbp_time_buffer=[]; mbp_pressure_buffer=[];
                    mbp_pressure10hz_buffer=[]; mbp_gradient_buffer=[];
                    phaseStartIdx=NaN; phaseStartTime=[]; phaseStartTime_sec=NaN;
                    samplesSinceDrop=0; controlWindowCheck=false; controlWindow=false;
                    controlWindow_startTime=[]; controlWindow_startTime_sec=NaN; controlWindow_Fluctuation=false;
                    continue
                end
            end
        end

        if skipBC_due_to_SV
            if abs(mbp_gradient(k)) < GradientStableThreshold
                if ~sv_hold_active
                    sv_hold_active    = true;
                    sv_hold_start_sec = mbp_time_sec(k);
                else
                    if (mbp_time_sec(k) - sv_hold_start_sec) >= SV_EndStableHold_s
                        % Flag to force end this phase at current k
                        forceEnd_SV = true;

                    end
                end
            else
                % broke stability → reset the hold
                sv_hold_active    = false;
                sv_hold_start_sec = NaN;
            end
        end
        % (B) Stream BC causally up to t_now_sec (same as now)
        % BC streaming (only if NOT skipping due to SV)
        %   - collect time/pressure/gradient + telemetry sample-by-sample
        %   - marks threshold crossing
        %   - streams up to mbp_time_sec(k) (Current time, causal loop)
        % -----------------------------------------------------------------
        if ~skipBC_due_to_SV && numBC>0 %
            for bcIdx = 1:numBC
                if ~bc_isActive(bcIdx), continue; end

                % On the first captured sample, check starting pressure guard
                if isempty(bc_pressure_buffer{bcIdx}) && (BC(bcIdx).idx_pointer <= numel(BC(bcIdx).time_sec))
                    if BC(bcIdx).time_sec(BC(bcIdx).idx_pointer) <= mbp_time_sec(k)
                        if BC(bcIdx).pressure(BC(bcIdx).idx_pointer) >= BC_BuildupPhase_P
                            % Code Update: mark all the specific sensors first
                            %bc_sensor_error_flag(bcIdx) = true;   % flag the problem
                            % Code Update: mark the actual problem
                            bc_start_above_thresh(bcIdx) = true; 
                            % Optional (keep a per-BC flag you can inspect later):
                            %if ~isfield(BC(bcIdx),'startAboveThresh'), BC(bcIdx).startAboveThresh = true; end
                            if verbose
                                fprintf('    [BC %s] Bad Start ≥ %.2f bar → SensorError=true (kept and recorded)\n', ...
                                    char(BC(bcIdx).id), BC_BuildupPhase_P);
                            end
                            % Do NOT set bc_isActive = false; DO NOT continue;
                            % fall through to normal ingestion so data is captured.

                        end
                    end
                end

                % Collect all samples up to current MBP time
                while BC(bcIdx).idx_pointer <= numel(BC(bcIdx).time_sec) && BC(bcIdx).time_sec(BC(bcIdx).idx_pointer) <= mbp_time_sec(k)
                    bc_time_buffer{bcIdx}(end+1,1)     = BC(bcIdx).time(BC(bcIdx).idx_pointer);
                    bc_time_buffer_sec{bcIdx}(end+1,1) = BC(bcIdx).time_sec(BC(bcIdx).idx_pointer);
                    bc_pressure_buffer{bcIdx}(end+1,1) = BC(bcIdx).pressure(BC(bcIdx).idx_pointer);
                    bc_pressure10hz_buffer{bcIdx}(end+1,1) = BC(bcIdx).pressure10hz(BC(bcIdx).idx_pointer);
                    bc_gradient_buffer{bcIdx}(end+1,1) = BC(bcIdx).gradient(BC(bcIdx).idx_pointer);

                    if ~isempty(BC(bcIdx).Vbatt),       bc_vbatt_buffer{bcIdx}(end+1,1) = BC(bcIdx).Vbatt(BC(bcIdx).idx_pointer);         end
                    if ~isempty(BC(bcIdx).Temperature), bc_temp_buffer{bcIdx}(end+1,1)  = BC(bcIdx).Temperature(BC(bcIdx).idx_pointer);   end
                    if ~isempty(BC(bcIdx).RSSI),        bc_rssi_buffer{bcIdx}(end+1,1)  = BC(bcIdx).RSSI(BC(bcIdx).idx_pointer);          end

                    if BC(bcIdx).pressure(BC(bcIdx).idx_pointer) >= BC_BuildupPhase_P + WV_fluctuation
                        bc_BrakingNormal_flag(bcIdx) = true;
                    end
                    BC(bcIdx).idx_pointer = BC(bcIdx).idx_pointer + 1;
                end
                
                % BC Control Window
                % Anomaly → SensorError (keep data)
                if ~bc_flat_checked(bcIdx) && numel(bc_time_buffer_sec{bcIdx}) >= 5
                    tFirst = bc_time_buffer_sec{bcIdx}(1);
                    span_s = bc_time_buffer_sec{bcIdx}(end) - tFirst;

                    if span_s >= 5
                        % Window within the first 5 seconds
                        mask_flat  = (bc_time_buffer_sec{bcIdx} - tFirst) <= 5;
                        press_flat = bc_pressure_buffer{bcIdx}(mask_flat);
                        grad_flat  = bc_gradient_buffer{bcIdx}(mask_flat);

                        dp       = max(press_flat) - min(press_flat);
                        meanP    = mean(press_flat,  'omitnan');
                        meanGrad = mean(grad_flat,   'omitnan');

                        flat = (abs(meanGrad) < 0.01 && dp < 0.05);

                        if verbose
                            fprintf('[BC %s] Start-check: dp=%.3f, meanP=%.3f, meanGrad=%.4f → ', ...
                                char(BC(bcIdx).id), dp, meanP, meanGrad);
                        end

                        % CASE 1: Flat start near zero → sensor disconnected
                        if flat && meanP < 0.05
                            bc_flat_start_near_zero(bcIdx) = true;
                            if verbose, fprintf('Flat near zero (sensor disconnected)\n'); end

                            % CASE 2: Flat start but NOT near zero → already engaged
                        elseif flat && meanP >= 0.05
                            bc_already_engaged_flag(bcIdx) = true;
                            if verbose, fprintf('Flat but non-zero (already engaged)\n'); end

                            % CASE 3: Negative start gradient → already releasing
                        elseif meanGrad < -0.01
                            bc_releasing_at_start_flag(bcIdx) = true;
                            if verbose, fprintf('Negative gradient (already releasing)\n'); end

                        else
                            if verbose, fprintf('No anomaly detected at start.\n'); end
                        end

                        if exist('flag_reason','var') && verbose
                            fprintf('    [BC %s] Start anomaly: %s\n', char(BC(bcIdx).id), flag_reason);
                        end

                        % Mark the start-check as completed ONLY AFTER doing it
                        bc_flat_checked(bcIdx) = true;

                    else
                        bc_flat_checked(bcIdx) = false;
                    end
                end
                % Code Update: mark as sensor error when at least one of the error condition is true
                if bc_start_above_thresh(bcIdx) || bc_flat_start_near_zero(bcIdx) || bc_already_engaged_flag(bcIdx) || bc_releasing_at_start_flag(bcIdx)
                    bc_sensor_error_flag(bcIdx) = true;
                    bc_badstart(bcIdx) = true;
                else
                    bc_sensor_error_flag(bcIdx) = false;
                    bc_badstart(bcIdx) = false;
                end
            end
        end
        % -----------------------------------------------------------------
        % Phase END condition (MBP)
        % -----------------------------------------------------------------
        endPressureTarget = initPressure - P_Release;

        regularEnd = (mbp_pressure(k) > endPressureTarget) && (mbp_gradient(k) > GradEndThresh);
        svEarlyEnd = (skipBC_due_to_SV && forceEnd_SV);
        % (C) Check MBP end condition at current k (same logic)
        if regularEnd || svEarlyEnd || SystemStopped
            phaseEndIdx  = k;
            totalDrop    = initPressure - min(mbp_pressure_buffer);
            if totalDrop >= Min_P_drop
                numPhases = numPhases + 1;

                SV_Error = (initPressure > MBP_Upper);
                UP_Error = (initPressure < MBP_Lower);

                % ===================== COMMIT: MBP ===========================
                TestBrake(numPhases).PhaseIdx           = numPhases;
                TestBrake(numPhases).MBP_Label          = mbp_label;
                TestBrake(numPhases).MBP_Time           = mbp_time_buffer;
                TestBrake(numPhases).MBP_Pressure       = mbp_pressure_buffer;
                TestBrake(numPhases).MBP_Pressure10hz   = mbp_pressure10hz_buffer;
                TestBrake(numPhases).MBP_Gradient       = mbp_gradient_buffer;
                TestBrake(numPhases).SV_Error           = logical(SV_Error);
                TestBrake(numPhases).UP_Error           = logical(UP_Error);
                TestBrake(numPhases).EmergencyBrake     = (totalDrop >= EmergencyBraking);
                TestBrake(numPhases).InitPressure       = initPressure;
                TestBrake(numPhases).MBP_StartIdx       = phaseStartIdx;
                TestBrake(numPhases).MBP_StartTime      = mbp_time(phaseStartIdx);
                TestBrake(numPhases).MBP_EndOfBrakeIdx  = phaseEndIdx;
                TestBrake(numPhases).MBP_EndOfBrakeTime = mbp_time(phaseEndIdx);
                TestBrake(numPhases).MBP_TestIndex      = mbp_row_index;
                TestBrake(numPhases).MBP_ID             = mbp_id;

                % Ensure post fields exist now (default NaN)
                TestBrake(numPhases).Post20s_Valid        = false;
                TestBrake(numPhases).Post20s_Time         = [];
                TestBrake(numPhases).Post20s_MBP_Pressure = NaN;
                TestBrake(numPhases).Post20s_BC_Pressure  = nan(numBC,1);

                TestBrake(numPhases).Post60s_Valid        = false;
                TestBrake(numPhases).Post60s_Time         = [];
                TestBrake(numPhases).Post60s_MBP_Pressure = NaN;
                TestBrake(numPhases).Post60s_BC_Pressure  = nan(numBC,1);

                % time limit relative to MBP end
                t_end_sec            = mbp_time_sec(phaseEndIdx);
                % ARM post20 / post60
                post20_active   = true;
                post20_tcap     = t_end_sec + 20;
                post20_phaseIdx = numPhases;

                post60_active   = true;
                post60_tcap     = t_end_sec + 60;
                post60_phaseIdx = numPhases;

                % Initialize per-BC cursors to the first sample AFTER MBP end (or at end)
                for bcIdx = 1:numBC
                    % move pointer to first BC sample with time_sec > t_end_sec
                    p = post20_bc_ptr(bcIdx);
                    while p <= numel(BC(bcIdx).time_sec) && BC(bcIdx).time_sec(p) <= t_end_sec
                        p = p + 1;
                    end
                    post20_bc_ptr(bcIdx) = p;

                    p = post60_bc_ptr(bcIdx);
                    while p <= numel(BC(bcIdx).time_sec) && BC(bcIdx).time_sec(p) <= t_end_sec
                        p = p + 1;
                    end
                    post60_bc_ptr(bcIdx) = p;
                end


                % MBP telemetry slices (index-based slice on MBP grid)
                idxSlice = phaseStartIdx:phaseEndIdx;
                TestBrake(numPhases).MBP_Vbatt       = mbp_vbatt_aligned(idxSlice);
                TestBrake(numPhases).MBP_Temperature = mbp_temp_aligned(idxSlice);
                TestBrake(numPhases).MBP_RSSI        = mbp_rssi_aligned(idxSlice);

                % --- after MBP commit ---
                t_end_sec = mbp_time_sec(phaseEndIdx);

                bcExtend_sec = t_end_sec + BC_ExtendAfterMBP_s;

                closingPhase    = true;
                closingPhaseIdx = numPhases;      % <--- important
                inBraking       = false;
                if verbose
                    fprintf('  [Phase %d] -> CLOSING: BC extension until t=%.3fs (now=%.3fs, +%.1fs)\n', ...
                        closingPhaseIdx, bcExtend_sec, t_now_sec, BC_ExtendAfterMBP_s);
                end

                % Allocate BC container ONCE (do not do it every k)
                TestBrake(closingPhaseIdx).BC = repmat(struct( ...
                    'Label',"", ...
                    'Time',[], 'Pressure',[], 'Pressure10hz',[], 'Gradient',[], ...
                    'Vbatt',[], 'Temperature',[], 'RSSI',[], ...
                    'SensorError',false, ...
                    'NormalBraking',false, ...
                    'BadStart',false, ...
                    'LowBraking',false, ...
                    'StartAboveThresh',false, ...
                    'FlatStartNearZero',false, ...
                    'AlreadyEngagedStart',false, ...
                    'ReleasingAtStart',false, ...
                    'StartTime',[], 'EndTime',[], ...
                    'TestIndex',NaN, 'ID',[], ...
                    'MaxPressure', NaN, ...
                    'EndPressure', NaN), ...
                    numBC,1);

                
            else
                if verbose
                    fprintf('[Phase %d] MBP discarded: ΔP=%.3f < %.3f\n', numPhases+1, totalDrop, Min_P_drop);
                end
            end
        end
    end

    % ==========================================================
    % 2) If we are in CLOSING PHASE: BC extension is causal
    % ==========================================================
    if closingPhase

        % Stream BC ONLY up to current time t_now_sec (still causal)
        if ~skipBC_due_to_SV && numBC > 0
            for bcIdx = 1:numBC % number of BC Channel
                if ~bc_isActive(bcIdx), continue; end

                while BC(bcIdx).idx_pointer <= numel(BC(bcIdx).time_sec) && ...
                      BC(bcIdx).time_sec(BC(bcIdx).idx_pointer) <= t_now_sec % is until t_now_sec
                
                    % append BC sample (time/pressure/grad/telemetry)
                    % update end-condition detection using only available samples
                    % idx_pointer++
                    bc_time_buffer{bcIdx}(end+1,1)     = BC(bcIdx).time(BC(bcIdx).idx_pointer);
                    bc_time_buffer_sec{bcIdx}(end+1,1) = BC(bcIdx).time_sec(BC(bcIdx).idx_pointer);
                    bc_pressure_buffer{bcIdx}(end+1,1) = BC(bcIdx).pressure(BC(bcIdx).idx_pointer);
                    bc_pressure10hz_buffer{bcIdx}(end+1,1) = BC(bcIdx).pressure10hz(BC(bcIdx).idx_pointer);
                    bc_gradient_buffer{bcIdx}(end+1,1) = BC(bcIdx).gradient(BC(bcIdx).idx_pointer);

                    if ~isempty(BC(bcIdx).Vbatt),       bc_vbatt_buffer{bcIdx}(end+1,1) = BC(bcIdx).Vbatt(BC(bcIdx).idx_pointer);         end
                    if ~isempty(BC(bcIdx).Temperature), bc_temp_buffer{bcIdx}(end+1,1)  = BC(bcIdx).Temperature(BC(bcIdx).idx_pointer);   end
                    if ~isempty(BC(bcIdx).RSSI),        bc_rssi_buffer{bcIdx}(end+1,1)  = BC(bcIdx).RSSI(BC(bcIdx).idx_pointer);          end

                    if BC(bcIdx).pressure(BC(bcIdx).idx_pointer) >= BC_BuildupPhase_P + WV_fluctuation
                        bc_BrakingNormal_flag(bcIdx) = true;
                    end
                    BC(bcIdx).idx_pointer = BC(bcIdx).idx_pointer + 1;

                    % End condition: P<0.4 and gradients mostly negative over window
                    ns = numel(bc_pressure_buffer{bcIdx});
                    if ns >= BC_EndWinSamples
                        pNow = bc_pressure_buffer{bcIdx}(ns);
                        gWin = bc_gradient_buffer{bcIdx}(ns-BC_EndWinSamples+1 : ns);
                        mostlyDown = mean(gWin < 0) > BC_EndMostlyDownFrac;
                        if (pNow < BC_EndThreshold) %&& mostlyDown
                            bc_isActive(bcIdx) = false;
                            break;
                        end
                    end

                end
            end
        end

        % If the extension horizon has elapsed, FINALIZE BC now
        if t_now_sec >= bcExtend_sec
            ph = closingPhaseIdx;  % stable phase reference
            if verbose
                fprintf('  [Phase %d] CLOSING FINALIZE at t=%.3fs (deadline=%.3fs)\n', ...
                    closingPhaseIdx, t_now_sec, bcExtend_sec);
            end

            % If SV_Error: mark all BC errors and do not interpret buffers
            if TestBrake(ph).SV_Error
                for bcIdx = 1:numBC
                    TestBrake(ph).BC(bcIdx).Label       = BC(bcIdx).label;
                    TestBrake(ph).BC(bcIdx).SensorError = true;
                    TestBrake(ph).BC(bcIdx).TestIndex   = BC(bcIdx).testIndex;
                    TestBrake(ph).BC(bcIdx).ID          = BC(bcIdx).id;
                end

            else
                for bcIdx = 1:numBC

                    hasData = ~isempty(bc_pressure_buffer{bcIdx}) && ~isempty(bc_time_buffer{bcIdx});

                    if hasData
                        startTimeBC = bc_time_buffer{bcIdx}(1);
                        endTimeBC   = bc_time_buffer{bcIdx}(end);
                        maxP        = max(bc_pressure_buffer{bcIdx});
                        endPressure = bc_pressure_buffer{bcIdx}(end);
                    else
                        startTimeBC = []; endTimeBC = []; maxP = NaN; endPressure = NaN;
                        bc_sensor_error_flag(bcIdx) = true;
                    end

                    % LowBraking if no sensor error but never reached normal threshold
                    if ~bc_sensor_error_flag(bcIdx) && ~bc_BrakingNormal_flag(bcIdx)
                        bc_LowBraking(bcIdx) = true;
                    end

                    % Commit buffers + flags
                    TestBrake(ph).BC(bcIdx).Label        = BC(bcIdx).label;
                    TestBrake(ph).BC(bcIdx).Time         = bc_time_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).Pressure     = bc_pressure_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).Pressure10hz = bc_pressure10hz_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).Gradient     = bc_gradient_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).Vbatt        = bc_vbatt_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).Temperature  = bc_temp_buffer{bcIdx};
                    TestBrake(ph).BC(bcIdx).RSSI         = bc_rssi_buffer{bcIdx};

                    TestBrake(ph).BC(bcIdx).BadStart     = logical(bc_badstart(bcIdx));
                    TestBrake(ph).BC(bcIdx).SensorError  = logical(bc_sensor_error_flag(bcIdx));
                    TestBrake(ph).BC(bcIdx).NormalBraking= logical(bc_BrakingNormal_flag(bcIdx));
                    TestBrake(ph).BC(bcIdx).LowBraking   = logical(bc_LowBraking(bcIdx));

                    TestBrake(ph).BC(bcIdx).StartAboveThresh    = logical(bc_start_above_thresh(bcIdx));
                    TestBrake(ph).BC(bcIdx).FlatStartNearZero   = logical(bc_flat_start_near_zero(bcIdx));
                    TestBrake(ph).BC(bcIdx).AlreadyEngagedStart = logical(bc_already_engaged_flag(bcIdx));
                    TestBrake(ph).BC(bcIdx).ReleasingAtStart    = logical(bc_releasing_at_start_flag(bcIdx));

                    TestBrake(ph).BC(bcIdx).StartTime   = startTimeBC;
                    TestBrake(ph).BC(bcIdx).EndTime     = endTimeBC;
                    TestBrake(ph).BC(bcIdx).TestIndex   = BC(bcIdx).testIndex;
                    TestBrake(ph).BC(bcIdx).ID          = BC(bcIdx).id;
                    TestBrake(ph).BC(bcIdx).MaxPressure = maxP;
                    TestBrake(ph).BC(bcIdx).EndPressure = endPressure;
                end
                if verbose
                    nErr = sum([TestBrake(ph).BC.SensorError]);
                    nLow = sum([TestBrake(ph).BC.LowBraking]);
                    fprintf('  [Phase %d] BC committed: numBC=%d | SensorError=%d | LowBraking=%d\n', ...
                        ph, numBC, nErr, nLow);
                end

            end
            % (A) For each BC compute:
            % - StartTime, EndTime, MaxPressure, EndPressure
            % - LowBraking classification (if no error and never reached threshold)
            % - write BC buffers + flags into TestBrake(phase).BC
            % (B) Commit WV/GPS if you want them aligned to the finalized end time
            % (optional: you can do WV earlier since WV is masked to MBP window in your current design)
            % ===================== COMMIT: WV ============================
            TestBrake(ph).WV = repmat(struct( ...
                'Label',"", 'Time',[], 'Pressure',[], ...
                'Vbatt',[], 'Temperature',[], 'RSSI',[], ...
                'WV_SensorError',false, 'StartTime',[], 'EndTime',[], ...
                'TestIndex',NaN, 'ID',[], ...
                'MeanPressure', NaN, ...
                'NumSamples',   0), ...
                numWV,1);

            if TestBrake(ph).SV_Error
                for wvIdx = 1:numWV
                    TestBrake(ph).WV(wvIdx).Label          = WV(wvIdx).label;
                    TestBrake(ph).WV(wvIdx).WV_SensorError = true;
                    TestBrake(ph).WV(wvIdx).TestIndex      = WV(wvIdx).testIndex;
                    TestBrake(ph).WV(wvIdx).ID             = WV(wvIdx).id;
                    TestBrake(ph).WV(wvIdx).MeanPressure   = NaN;
                    TestBrake(ph).WV(wvIdx).NumSamples     = 0;
                end
            else
                tStartNum = mbp_time_sec(TestBrake(ph).MBP_StartIdx);
                tEndNum   = mbp_time_sec(TestBrake(ph).MBP_EndOfBrakeIdx);

                for wvIdx = 1:numWV
                    maskWV = (WV(wvIdx).time_sec >= tStartNum) & (WV(wvIdx).time_sec <= tEndNum);
                    countWV = sum(maskWV);
                    if countWV == 0
                        TestBrake(ph).WV(wvIdx).Label           = WV(wvIdx).label;
                        TestBrake(ph).WV(wvIdx).WV_SensorError  = true;  % forced
                        TestBrake(ph).WV(wvIdx).TestIndex       = WV(wvIdx).testIndex;
                        TestBrake(ph).WV(wvIdx).ID              = WV(wvIdx).id;
                        TestBrake(ph).WV(wvIdx).NumSamples      = 0;
                    elseif countWV < 2
                        TestBrake(ph).WV(wvIdx).Label          = WV(wvIdx).label;
                        TestBrake(ph).WV(wvIdx).WV_SensorError = true;
                        TestBrake(ph).WV(wvIdx).TestIndex      = WV(wvIdx).testIndex;
                        TestBrake(ph).WV(wvIdx).ID             = WV(wvIdx).id;
                    else
                        TestBrake(ph).WV(wvIdx).Label        = WV(wvIdx).label;
                        TestBrake(ph).WV(wvIdx).Time         = WV(wvIdx).time(maskWV);
                        TestBrake(ph).WV(wvIdx).Pressure     = WV(wvIdx).pressure(maskWV);

                        if ~isempty(WV(wvIdx).Vbatt),       TestBrake(ph).WV(wvIdx).Vbatt       = WV(wvIdx).Vbatt(maskWV);       else, TestBrake(ph).WV(wvIdx).Vbatt       = []; end
                        if ~isempty(WV(wvIdx).Temperature), TestBrake(ph).WV(wvIdx).Temperature = WV(wvIdx).Temperature(maskWV); else, TestBrake(ph).WV(wvIdx).Temperature = []; end
                        if ~isempty(WV(wvIdx).RSSI),        TestBrake(ph).WV(wvIdx).RSSI        = WV(wvIdx).RSSI(maskWV);        else, TestBrake(ph).WV(wvIdx).RSSI        = []; end

                        TestBrake(ph).WV(wvIdx).StartTime    = WV(wvIdx).time(find(maskWV,1,'first'));
                        TestBrake(ph).WV(wvIdx).EndTime      = WV(wvIdx).time(find(maskWV,1,'last'));
                        TestBrake(ph).WV(wvIdx).TestIndex    = WV(wvIdx).testIndex;
                        TestBrake(ph).WV(wvIdx).ID           = WV(wvIdx).id;
                        TestBrake(ph).WV(wvIdx).MeanPressure = round(mean(WV(wvIdx).pressure(maskWV), 'omitnan'), 1);
                        TestBrake(ph).WV(wvIdx).NumSamples   = countWV;
                    end
                end
            end

            % ===================== COMMIT: GPS (flat fields) ============
            TestBrake(ph).GPS_Time        = datetime.empty(0,1);
            TestBrake(ph).GPS_Long        = [];
            TestBrake(ph).GPS_Lat         = [];
            TestBrake(ph).GPS_Speed       = [];
            TestBrake(ph).GPS_Speed_RPM   = [];
            TestBrake(ph).GPS_Ibatt       = [];
            TestBrake(ph).GPS_Vbatt       = [];
            TestBrake(ph).GPS_RPM_axle    = [];
            TestBrake(ph).GPS_StartTime   = [];
            TestBrake(ph).GPS_EndTime     = [];
            TestBrake(ph).GPS_NumSamples  = 0;
            TestBrake(ph).GPS_SensorError = false;

            if GPS.hasData
                % Find latest BC end time in this phase
                % ---- Find latest BC end time safely ----
                bcEndMax = NaN;
                if isfield(TestBrake(ph),'BC') && ~isempty(TestBrake(ph).BC)
                    bcEnds = [TestBrake(ph).BC.EndTime];

                    % Handle datetime or numeric cases
                    if isdatetime(bcEnds)
                        bcEnds = bcEnds(~isnat(bcEnds));      % remove NaT
                        if ~isempty(bcEnds)
                            bcEndMax = max(bcEnds);
                        end
                    elseif isnumeric(bcEnds)
                        bcEnds = bcEnds(~isnan(bcEnds));      % remove NaN
                        if ~isempty(bcEnds)
                            bcEndMax = max(bcEnds);
                        end
                    end
                end

                % Fallback to MBP phase end if BC end is missing
                if isdatetime(bcEndMax)
                    endTimeAbs = bcEndMax;
                elseif isnumeric(bcEndMax)
                    % Convert numeric BC end time to datetime if GPS.time is datetime
                    if isdatetime(GPS.time)
                        endTimeAbs = GPS.time(1) + seconds(bcEndMax - GPS.time_sec(1));
                    else
                        endTimeAbs = bcEndMax;
                    end
                else
                    endTimeAbs  = MBP.time(mbpEndIdx);
                end
                mbpStartIdx = TestBrake(ph).MBP_StartIdx;
                mbpEndIdx   = TestBrake(ph).MBP_EndOfBrakeIdx;
                tStartNum = mbp_time(mbpStartIdx);
                tEndNum   = endTimeAbs;
                maskGPS   = (gps_time >= tStartNum) & (gps_time <= tEndNum);
                nGPS      = sum(maskGPS);

                if nGPS < 2
                    TestBrake(ph).GPS_SensorError = true;
                else
                    TestBrake(ph).GPS_Time       = GPS.time(maskGPS);
                    if ~isempty(GPS.Long),      TestBrake(ph).GPS_Long      = GPS.Long(maskGPS);      end
                    if ~isempty(GPS.Lat),       TestBrake(ph).GPS_Lat       = GPS.Lat(maskGPS);       end
                    if ~isempty(GPS.Speed),     TestBrake(ph).GPS_Speed     = GPS.Speed(maskGPS);     end
                    if ~isempty(GPS.Speed_RPM), TestBrake(ph).GPS_Speed_RPM = GPS.Speed_RPM(maskGPS); end
                    if ~isempty(GPS.GPS_Ibatt), TestBrake(ph).GPS_Ibatt     = GPS.GPS_Ibatt(maskGPS); end
                    if ~isempty(GPS.GPS_Vbatt), TestBrake(ph).GPS_Vbatt     = GPS.GPS_Vbatt(maskGPS); end
                    if ~isempty(GPS.RPM_axle),  TestBrake(ph).GPS_RPM_axle  = GPS.RPM_axle(maskGPS);  end

                    TestBrake(ph).GPS_StartTime  = GPS.time(find(maskGPS,1,'first'));
                    TestBrake(ph).GPS_EndTime    = GPS.time(find(maskGPS,1,'last'));
                    TestBrake(ph).GPS_NumSamples = nGPS;
                end
            else
                TestBrake(ph).GPS_SensorError = true;
            end
            % (C) close the phase:
            closingPhase = false;
            % reset per-phase BC buffers/flags (prepare for next phase)
            
            % Reset per-phase MBP state
            inBraking=false; initPressure=NaN;
            mbp_time_buffer=[]; mbp_pressure_buffer=[]; mbp_gradient_buffer=[];
            phaseStartIdx=NaN; phaseStartTime=[]; phaseStartTime_sec=NaN;
            samplesSinceDrop=0; controlWindowCheck=false; controlWindow=false;
            controlWindow_startTime=[]; controlWindow_startTime_sec=NaN; controlWindow_Fluctuation=false;
            skipBC_due_to_SV = false; skipWV_due_to_SV = false;
            sv_hold_active=false; sv_hold_start_sec=NaN;

            if verbose
                fprintf('  [Phase %d] DONE. Return to scan.\n\n', ph);
            end
        end
    end


    % ==========================================================
    % 3) If neither inBraking nor closingPhase:
    %    scan for new MBP onset (same as now)
    % ==========================================================
    if ~inBraking && ~closingPhase
        % Phase Braking condition
        windowStart = max(1, k - windowSize + 1);
        windowIdx   = windowStart:k;
        isStableNow = (sum(abs(mbp_gradient(windowIdx)) <= GradZeroTol) >= StablePointCount);

        if isStableNow && (mbp_gradient(k) <= InitGrad_Thresh) && mbp_pressure(k) > MBP_Lower
            % We are about to start a new phase, cancel post time check captures if the drop are within the time limit
            % t_drop = mbp_time_sec(k);
            % if post20_check.active && (t_drop < post20_check.time_limit), post20_check.active = false; end
            % if post60_check.active && (t_drop < post60_check.time_limit), post60_check.active = false; end
            t_drop = mbp_time_sec(k);
            if post20_active && (t_drop < post20_tcap), post20_active = false; end
            if post60_active && (t_drop < post60_tcap), post60_active = false; end


            inBraking            = true;
            initPressure         = mbp_pressure(k);
            phaseStartIdx        = k;
            phaseStartTime       = mbp_time(k);
            phaseStartTime_sec   = mbp_time_sec(k);

            % Start per-phase MBP buffers
            mbp_time_buffer      = mbp_time(k);
            mbp_pressure_buffer  = mbp_pressure(k);
            mbp_pressure10hz_buffer = mbp_pressure10hz(k);
            mbp_gradient_buffer  = mbp_gradient(k);

            if verbose
                fprintf('\n[Phase %d] START detected at k=%d, t=%.3fs | P=%.2f, G=%.4f | stable=%d\n', ...
                    numPhases+1, k, t_now_sec, mbp_pressure(k), mbp_gradient(k), isStableNow);

                fprintf('  Guards reset | skipBC_due_to_SV=%d (InitP=%.2f, MBP_Upper=%.2f)\n', ...
                    skipBC_due_to_SV, initPressure, MBP_Upper);

                if ~skipBC_due_to_SV
                    fprintf('  BC streams armed: numBC=%d (idx_pointer aligned to phaseStartTime_sec=%.3fs)\n', ...
                        numBC, phaseStartTime_sec);
                else
                    fprintf('  SV onset: BC/WV will be skipped; SV hold-based early end is active.\n');
                end
            end


            % Reset guards
            samplesSinceDrop=0; controlWindowCheck=false; controlWindow=false;
            controlWindow_startTime=[]; controlWindow_startTime_sec=NaN; controlWindow_Fluctuation=false;
            % Long-stop guard state
            SystemStopped = false;

            % Decide SV skip (applies to BC and WV)
            skipBC_due_to_SV = (initPressure > MBP_Upper);
            skipWV_due_to_SV = skipBC_due_to_SV;
            if skipBC_due_to_SV && verbose
                fprintf('  [Phase %d] SV_Error=1 at onset — skipping BC & WV this phase.\n', numPhases+1);
            end

            % Prep BC stream cursors and buffers if not skipping
            if ~skipBC_due_to_SV
                for bcIdx = 1:numBC
                    bc_isActive(bcIdx)   = true;

                    if isdatetime(BC(bcIdx).time), bc_time_buffer{bcIdx} = BC(bcIdx).time([]); else, bc_time_buffer{bcIdx} = []; end
                    bc_time_buffer_sec{bcIdx}     = [];
                    bc_pressure_buffer{bcIdx}     = [];
                    bc_pressure10hz_buffer{bcIdx} = [];
                    bc_gradient_buffer{bcIdx}     = [];
                    bc_vbatt_buffer{bcIdx}        = [];
                    bc_temp_buffer{bcIdx}         = [];
                    bc_rssi_buffer{bcIdx}         = [];

                    bc_start_above_thresh(bcIdx)      = false;
                    bc_flat_start_near_zero(bcIdx)    = false;
                    bc_already_engaged_flag(bcIdx)    = false;
                    bc_releasing_at_start_flag(bcIdx) = false;
                    bc_flat_checked(bcIdx)            = false;
                    bc_BrakingNormal_flag(bcIdx)      = false;
                    bc_sensor_error_flag(bcIdx)       = false;
                    bc_badstart(bcIdx)                = false;
                    bc_marked_end_flag(bcIdx)         = false;
                    bc_LowBraking(bcIdx)              = false;

                    % Move idx_pointer to first sample at/after onset
                    while (BC(bcIdx).idx_pointer <= numel(BC(bcIdx).time_sec)) && (BC(bcIdx).time_sec(BC(bcIdx).idx_pointer) < phaseStartTime_sec)
                        BC(bcIdx).idx_pointer = BC(bcIdx).idx_pointer + 1;
                    end
                end
            end
        end
    end

    % ==========================================================
    % 4) post20/post60 capture (same as now)
    % ==========================================================
    % Uses current k time, so it is already causal.
    if post20_active && (t_now_sec >= post20_tcap)
        ph    = post20_phaseIdx;
        t_cap = post20_tcap;

        % Ensure fields exist
        if ~isfield(TestBrake(ph),'Post20s_Valid')
            TestBrake(ph).Post20s_Valid        = false;
            TestBrake(ph).Post20s_Time         = [];
            TestBrake(ph).Post20s_MBP_Pressure = NaN;
            TestBrake(ph).Post20s_BC_Pressure  = nan(numBC,1);
        end

        % MBP sample-hold at t_cap (causal on MBP grid)
        idx_mbp = find(mbp_time_sec <= t_cap, 1, 'last');
        if isempty(idx_mbp)
            TestBrake(ph).Post20s_Valid = false;
        else
            TestBrake(ph).Post20s_Valid = true;
            if mbp_is_datetime
                TestBrake(ph).Post20s_Time = mbp_t0 + seconds(t_cap);
            else
                TestBrake(ph).Post20s_Time = t_cap;
            end
            TestBrake(ph).Post20s_MBP_Pressure = mbp_pressure(idx_mbp);
            
            % ---- BC causal hold using independent pointers ----
            BC_Press = nan(numBC,1);
            % if verbose
            %     fprintf('[Post20] t_cap=%.3f, BC last times:', t_cap);
            %     for bcIdx=1:numBC
            %         p = post20_bc_ptr(bcIdx);
            %         fprintf(' %s->ptr=%d', char(BC(bcIdx).id), p);
            %     end
            %     fprintf('\n');
            % end

            for bcIdx = 1:numBC
                p = post20_bc_ptr(bcIdx);

                % advance pointer while BC time <= t_cap
                lastP = NaN;
                while p <= numel(BC(bcIdx).time_sec) && BC(bcIdx).time_sec(p) <= t_cap
                    lastP = p;
                    p = p + 1;
                end

                % store updated pointer back
                post20_bc_ptr(bcIdx) = p;

                % sample-hold = lastP (last time <= t_cap)
                if ~isnan(lastP)
                    BC_Press(bcIdx) = BC(bcIdx).pressure(lastP);
                else
                    % no BC sample after MBP end up to t_cap => remain NaN
                    BC_Press(bcIdx) = NaN;
                end
            end
            TestBrake(ph).Post20s_BC_Pressure = BC_Press;
        end

        post20_active = false; % consume
    end

    if post60_active && (t_now_sec >= post60_tcap)
        ph    = post60_phaseIdx;
        t_cap = post60_tcap;

        % Ensure fields exist
        if ~isfield(TestBrake(ph),'Post60s_Valid')
            TestBrake(ph).Post60s_Valid        = false;
            TestBrake(ph).Post60s_Time         = [];
            TestBrake(ph).Post60s_MBP_Pressure = NaN;
            TestBrake(ph).Post60s_BC_Pressure  = nan(numBC,1);
        end

        % MBP sample-hold at t_cap (causal on MBP grid)
        idx_mbp = find(mbp_time_sec <= t_cap, 1, 'last');
        if isempty(idx_mbp)
            TestBrake(ph).Post60s_Valid = false;
        else
            TestBrake(ph).Post60s_Valid = true;
            if mbp_is_datetime
                TestBrake(ph).Post60s_Time = mbp_t0 + seconds(t_cap);
            else
                TestBrake(ph).Post60s_Time = t_cap;
            end
            TestBrake(ph).Post60s_MBP_Pressure = mbp_pressure(idx_mbp);

            % ---- BC causal hold using independent pointers ----
            BC_Press = nan(numBC,1);
            for bcIdx = 1:numBC
                p = post60_bc_ptr(bcIdx);

                % advance pointer while BC time <= t_cap
                lastP = NaN;
                while p <= numel(BC(bcIdx).time_sec) && BC(bcIdx).time_sec(p) <= t_cap
                    lastP = p;
                    p = p + 1;
                end

                % store updated pointer back
                post60_bc_ptr(bcIdx) = p;

                % sample-hold = lastP (last time <= t_cap)
                if ~isnan(lastP)
                    BC_Press(bcIdx) = BC(bcIdx).pressure(lastP);
                else
                    % no BC sample after MBP end up to t_cap => remain NaN
                    BC_Press(bcIdx) = NaN;
                end
            end
            TestBrake(ph).Post60s_BC_Pressure = BC_Press;
        end

        post60_active = false; % consume
    end


    % if post20_check.active && (t_now_sec >= post20_check.time_limit)
    %     ph = post20_check.phaseIdx;
    % 
    %     % numeric end time of that phase
    %     if mbp_is_datetime
    %         t_end_s = seconds(TestBrake(ph).MBP_EndOfBrakeTime - mbp_t0);
    %     else
    %         t_end_s = TestBrake(ph).MBP_EndOfBrakeTime;
    %     end
    %     t_cap = post20_check.time_limit;
    % 
    %     % MBP stability over (t_end, t_cap]
    %     mask   = (mbp_time_sec > t_end_s) & (mbp_time_sec <= t_cap);
    %     % Code Update: no need to check for mbp gradient stability
    %     stable = ~isempty(mbp_time_sec(mask)); % && all(abs(mbp_gradient(mask)) < StableTol_Post);
    % 
    %     % ensure fields exist
    %     if ~isfield(TestBrake(ph),'Post20s_Valid')
    %         TestBrake(ph).Post20s_Valid        = false;
    %         TestBrake(ph).Post20s_Time         = [];
    %         TestBrake(ph).Post20s_MBP_Pressure = NaN;
    %         TestBrake(ph).Post20s_BC_Pressure  = nan(numBC,1);
    %     end
    % 
    %     if stable
    %         TestBrake(ph).Post20s_Valid        = true;
    % 
    %         if mbp_is_datetime
    %             TestBrake(ph).Post20s_Time = mbp_t0 + seconds(t_cap);
    %         else
    %             TestBrake(ph).Post20s_Time = t_cap;
    %         end
    % 
    %         TestBrake(ph).Post20s_MBP_Pressure = interp1(mbp_time_sec, mbp_pressure, t_cap, 'nearest','extrap');
    % 
    %         if numBC > 0
    %             BC_Press = nan(numBC,1);
    %             for r = 1:numBC
    %                 if ~isempty(BC(r).time_sec) && ~isempty(BC(r).pressure)
    %                     BC_Press(r) = interp1(BC(r).time_sec, BC(r).pressure, t_cap, 'nearest','extrap');
    %                 end
    %             end
    %             TestBrake(ph).Post20s_BC_Pressure = BC_Press;
    %         end
    %     else
    %         TestBrake(ph).Post20s_Valid = false;  % leave NaNs
    %     end
    % 
    %     post20_check.active = false; % consume
    % end
    % 
    % % ---- +60s ----
    % if post60_check.active && (t_now_sec >= post60_check.time_limit)
    %     ph = post60_check.phaseIdx;
    % 
    %     if mbp_is_datetime
    %         t_end_s = seconds(TestBrake(ph).MBP_EndOfBrakeTime - mbp_t0);
    %     else
    %         t_end_s = TestBrake(ph).MBP_EndOfBrakeTime;
    %     end
    %     t_cap = post60_check.time_limit;
    % 
    %     mask   = (mbp_time_sec > t_end_s) & (mbp_time_sec <= t_cap);
    %     % Code Update: no need to check for mbp gradient stability
    %     stable = ~isempty(mbp_time_sec(mask)); % && all(abs(mbp_gradient(mask)) < StableTol_Post);
    % 
    %     if ~isfield(TestBrake(ph),'Post60s_Valid')
    %         TestBrake(ph).Post60s_Valid        = false;
    %         TestBrake(ph).Post60s_Time         = [];
    %         TestBrake(ph).Post60s_MBP_Pressure = NaN;
    %         TestBrake(ph).Post60s_BC_Pressure  = nan(numBC,1);
    %     end
    % 
    %     if stable
    %         TestBrake(ph).Post60s_Valid        = true;
    % 
    %         if mbp_is_datetime
    %             TestBrake(ph).Post60s_Time = mbp_t0 + seconds(t_cap);
    %         else
    %             TestBrake(ph).Post60s_Time = t_cap;
    %         end
    % 
    %         TestBrake(ph).Post60s_MBP_Pressure = interp1(mbp_time_sec, mbp_pressure, t_cap, 'nearest','extrap');
    % 
    %         if numBC > 0
    %             BC_Press = nan(numBC,1);
    %             for r = 1:numBC
    %                 if ~isempty(BC(r).time_sec) && ~isempty(BC(r).pressure)
    %                     BC_Press(r) = interp1(BC(r).time_sec, BC(r).pressure, t_cap, 'nearest','extrap');
    %                 end
    %             end
    %             TestBrake(ph).Post60s_BC_Pressure = BC_Press;
    %         end
    %     else
    %         TestBrake(ph).Post60s_Valid = false;  % leave NaNs
    %     end
    % 
    %     post60_check.active = false; % consume
    % end
    % % ===== end post check block =====

end

if verbose, fprintf('[detect_MBP_BC_WV_to_struct] Done. Phases: %d\n', numPhases); end
end

