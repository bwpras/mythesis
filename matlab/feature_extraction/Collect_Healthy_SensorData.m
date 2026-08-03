function UsableData = Collect_Healthy_SensorData(TestBrake, numBC_expected, numWV_expected, MaxWindowHours)
% COLLECT_UNIQUE_HEALTHY_FROM_TESTBRAKE_WIN (simplified)
% Collect all healthy, unique BC and WV sensors within a time window of ≤ MaxWindowHours.
% Each BC/WV entry includes phase and index info; MBP_ID stored once at top level.
%
% Health rules:
%   BC healthy  = SensorError==0 && BrakingAct==1
%   WV healthy  = WV_SensorError==0 && NumSamples>0
%
% Usage:
%   UsableData = collect_unique_healthy_from_TestBrake_win(TestBrake, 4, 4);
%   UsableData = collect_unique_healthy_from_TestBrake_win(TestBrake, inf, inf, 2);

    if nargin < 2 || isempty(numBC_expected), numBC_expected = detect_expected(TestBrake,"BC"); end
    if nargin < 3 || isempty(numWV_expected), numWV_expected = detect_expected(TestBrake,"WV"); end
    if nargin < 4, MaxWindowHours = 2; end

    % ---- MBP_ID once (assumed constant) ----
    UsableData.MBP_ID = string(TestBrake(1).MBP_ID);

    % ---- Phase reference times ----
    numPhase = numel(TestBrake);
    phaseT = NaT(numPhase,1);
    for k = 1:numPhase
        phaseT(k) = TestBrake(k).MBP_StartTime;
    end
    [phaseT, idxOrder] = sort(phaseT);

    % ---- Sliding window search ----
    best = struct('BC',[],'WV',[],'PickedBC_IDs',[],'PickedWV_IDs',[],'WindowIdx',[],'TimeWindowOK',false);
    success = false;
    for s = 1:numPhase
        t0 = phaseT(s);
        if isnat(t0), continue; end

        % Window: [t0, t0 + MaxWindowHours]
        inWin = phaseT >= t0 & phaseT <= t0 + hours(MaxWindowHours);
        winIdx = idxOrder(inWin);

        % --- Collect within window ---
        [BC_list, WV_list, pickedBC, pickedWV] = collect_in_window(TestBrake, winIdx, numBC_expected, numWV_expected);

        if numel(pickedBC) >= numBC_expected && numel(pickedWV) >= numWV_expected
            best.BC = BC_list; best.WV = WV_list;
            best.PickedBC_IDs = pickedBC; best.PickedWV_IDs = pickedWV;
            best.WindowIdx = winIdx;
            best.TimeWindowOK = true;
            success = true;
            break
        else
            if numel(pickedBC) + numel(pickedWV) > numel(best.PickedBC_IDs) + numel(best.PickedWV_IDs)
                best.BC = BC_list; best.WV = WV_list;
                best.PickedBC_IDs = pickedBC; best.PickedWV_IDs = pickedWV;
                best.WindowIdx = winIdx;
            end
        end
    end

    % ---- Finalize output ----
    UsableData.BC = best.BC;
    UsableData.WV = best.WV;
    UsableData.PickedBC_IDs = best.PickedBC_IDs;
    UsableData.PickedWV_IDs = best.PickedWV_IDs;
    UsableData.WindowPhaseIdx = best.WindowIdx;
    UsableData.TimeWindowOK = success;
    if success
        UsableData.Note = "All quotas met within 2-hour window.";
    else
        UsableData.Note = "Quotas not fully met within any 2-hour window.";
    end
end

%% ---- Helper: collect within one window ----
function [BC_list, WV_list, pickedBC, pickedWV] = collect_in_window(TestBrake, winIdx, numBC_expected, numWV_expected)
    pickedBC = strings(0,1);
    pickedWV = strings(0,1);
    BC_list = struct('ID',{},'Label',{},'MaxPressure',{},'FromPhaseIdx',{},'IndexInPhase',{});
    WV_list = struct('ID',{},'Label',{},'MeanPressure',{},'FromPhaseIdx',{},'IndexInPhase',{});

    for jj = 1:numel(winIdx)
        k = winIdx(jj);

        % --- BC ---
        bc = TestBrake(k).BC(:);
        healthy = [bc.SensorError]==0 & [bc.NormalBraking]==1;
        ids = string({bc.ID});
        newIdx = find(healthy & ~ismember(ids,pickedBC));
        for ii = newIdx
            if numel(pickedBC) >= numBC_expected, break; end
            pickedBC(end+1,1) = ids(ii);
            BC_list(end+1) = struct( ...
                'ID', ids(ii), ...
                'Label', string(bc(ii).Label), ...
                'MaxPressure', double(bc(ii).MaxPressure), ...
                'FromPhaseIdx', k, ...
                'IndexInPhase', ii );
        end

        % --- WV ---
        wv = TestBrake(k).WV(:);
        healthy = [wv.WV_SensorError]==0 & [wv.NumSamples]>0;
        ids = string({wv.ID});
        newIdx = find(healthy & ~ismember(ids,pickedWV));
        for ii = newIdx
            if numel(pickedWV) >= numWV_expected, break; end
            pickedWV(end+1,1) = ids(ii);
            WV_list(end+1) = struct( ...
                'ID', ids(ii), ...
                'Label', string(wv(ii).Label), ...
                'MeanPressure', double(wv(ii).MeanPressure), ...
                'FromPhaseIdx', k, ...
                'IndexInPhase', ii );
        end

        if numel(pickedBC) >= numBC_expected && numel(pickedWV) >= numWV_expected
            break
        end
    end
end

%% ---- Helper: detect expected sensors ----
function n = detect_expected(TestBrake, whichField)
    ids = strings(0,1);
    for kk = 1:numel(TestBrake)
        if isfield(TestBrake(kk), whichField) && ~isempty(TestBrake(kk).(whichField))
            arr = TestBrake(kk).(whichField);
            ids = [ids; string({arr.ID})']; %#ok<AGROW>
        end
    end
    ids = unique(ids(ids~=""));
    n = max(1, numel(ids));
end
