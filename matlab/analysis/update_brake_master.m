function TestBrake_Master = update_brake_master(NewRun, varargin)
%UPDATE_BRAKE_MASTER  Merge a new run into the global master table and write per-folder masters.
%
% TestBrake_Master = update_brake_master(NewRun, 'Name', Value, ...)
%
% Required variables in NewRun (strings/datetimes recommended):
%   {'MBP_ID','BC_ID','WV_ID','Start_brake_time_pipe','End_brake_time_pipe'}
% Optional provenance columns (recommended):
%   {'RunFile','RunFolder'}
%
% Name-Value options
%   'KeyColumns'        cellstr, default: same as above
%   'TimeTolerance'     duration (rounding before keying), default: seconds(0)
%   'PreferNew'         logical, default: true (keep NEW row on duplicate)
%   'AllRunPath'        char/str, default: 'TestBrake_Master.mat'
%   'PerFolderPattern'  char/str, default: '%s_Master.mat'  (uses RunFolder)
%   'WriteCSV'          logical, default: false (also write CSV mirrors)
%
% Output
%   TestBrake_Master : merged, de-duplicated, time-sorted table (global)

    % ---------- Options ----------
    ip = inputParser;
    addParameter(ip,'KeyColumns',       {'MBP_ID','BC_ID','WV_ID','Start_brake_time_pipe','End_brake_time_pipe'});
    addParameter(ip,'TimeTolerance',    seconds(0));
    addParameter(ip,'PreferNew',        true);
    addParameter(ip,'AllRunPath',       'TestBrake_Master.mat');
    addParameter(ip,'PerFolderPattern', '%s_Master.mat');
    addParameter(ip,'WriteCSV',         false);
    parse(ip, varargin{:});
    opt = ip.Results;

    keyCols = opt.KeyColumns;

    % ---------- 0) Load existing global master (if any) ----------
    TestBrake_Master = table();
    if isfile(opt.AllRunPath)
        S = load(opt.AllRunPath);
        if isfield(S,'TestBrake_Master')
            TestBrake_Master = S.TestBrake_Master;
        else
            fn = fieldnames(S);
            if ~isempty(fn) && istable(S.(fn{1}))
                TestBrake_Master = S.(fn{1});
            end
        end
    end

    % ---------- 1) Ensure columns and normalize types ----------
    NewRun         = ensureRequiredColumns(NewRun,  keyCols);
    TestBrake_Master  = ensureRequiredColumns(TestBrake_Master, keyCols);

    NewRun         = normalizeTypes(NewRun);
    TestBrake_Master  = normalizeTypes(TestBrake_Master);

    % ---------- 2) Optional rounding to reduce near-duplicate keys ----------
    if opt.TimeTolerance > seconds(0)
        NewRun.Start_brake_time_pipe = roundDatetime(NewRun.Start_brake_time_pipe, opt.TimeTolerance);
        NewRun.End_brake_time_pipe   = roundDatetime(NewRun.End_brake_time_pipe,   opt.TimeTolerance);
        if ~isempty(TestBrake_Master)
            TestBrake_Master.Start_brake_time_pipe = roundDatetime(TestBrake_Master.Start_brake_time_pipe, opt.TimeTolerance);
            TestBrake_Master.End_brake_time_pipe   = roundDatetime(TestBrake_Master.End_brake_time_pipe,   opt.TimeTolerance);
        end
    end

    % ---------- 3) Build composite keys & decide rows to add ----------
    % Correct MATLAB format: months=MM, minutes=mm, fractions=SSS, literal T quoted
    keyFormat = "yyyyMMdd'T'HHmmss.SSS";

    newKey = buildCompositeKey(NewRun,        keyCols, keyFormat);
    masKey = buildCompositeKey(TestBrake_Master, keyCols, keyFormat);

    if isempty(TestBrake_Master)
        toAdd = true(height(NewRun),1);
    else
        toAdd = ~ismember(newKey, masKey);
    end

    % If preferring NEW rows, drop old duplicates already in master
    if opt.PreferNew && ~isempty(TestBrake_Master)
        dupInMaster = ismember(masKey, newKey);
        TestBrake_Master(dupInMaster,:) = [];
        masKey(dupInMaster) = [];
    end

    % ---------- 4) Align schemas & append ----------
    [TestBrake_Master, NewRunAligned] = alignSchemas(TestBrake_Master, NewRun);
    TestBrake_Master = [TestBrake_Master; NewRunAligned(toAdd,:)];

    % Safety net: enforce uniqueness by key (stable)
    if height(TestBrake_Master) > 0
        allKey = buildCompositeKey(TestBrake_Master, keyCols, keyFormat);
        [~, ia] = unique(allKey, 'stable');
        TestBrake_Master = TestBrake_Master(ia,:);
    end

    % ---------- 5) Sort globally ----------
    if any(strcmp('Start_brake_time_pipe', TestBrake_Master.Properties.VariableNames))
        TestBrake_Master = sortrows(TestBrake_Master, 'Start_brake_time_pipe', 'ascend');
    end

    % ---------- 6) Save global master ----------
    save(opt.AllRunPath, 'TestBrake_Master', '-v7.3');
    if opt.WriteCSV
        try
            writetable(TestBrake_Master, replace(string(opt.AllRunPath), '.mat', '.csv'));
        catch ME
            warning('update_brake_master:CSVGlobal','CSV write failed: %s', ME.message);
        end
    end

    % ---------- 7) Save per-folder masters (e.g., Dati10_Master.mat) ----------
    if ismember('RunFolder', TestBrake_Master.Properties.VariableNames)
        try
            writePerFolderMasters(TestBrake_Master, 'RunFolder', opt.PerFolderPattern, opt.WriteCSV);
        catch ME
            warning('update_brake_master:PerFolder','Per-folder write failed: %s', ME.message);
        end
    else
        warning('update_brake_master:PerFolder','RunFolder column not found; skipping per-folder masters.');
    end
end

% ===== Helper functions (readable names) =====

function T = ensureRequiredColumns(T, keyCols)
    if isempty(T)
        T = table( ...
            strings(0,1), strings(0,1), strings(0,1), ...
            datetime.empty(0,1), datetime.empty(0,1), ...
            'VariableNames', keyCols);
        return
    end
    for c = keyCols(:).'
        v = string(c);
        if ~ismember(v, T.Properties.VariableNames)
            switch v
                case {'Start_brake_time_pipe','End_brake_time_pipe'}
                    T.(v) = NaT(height(T),1);  % tz-naive
                otherwise
                    T.(v) = strings(height(T),1);
            end
        end
    end
end

function T = normalizeTypes(T)
    vn = T.Properties.VariableNames;

    % IDs → string
    idVars = intersect(vn, {'MBP_ID','BC_ID','WV_ID'});
    for v = idVars
        T.(v{1}) = string(T.(v{1}));
    end

    % Times → tz-naive datetime (robust parsing if needed)
    timeVars = intersect(vn, {'Start_brake_time_pipe','End_brake_time_pipe'});
    for v = timeVars
        x = T.(v{1});
        if ~isdatetime(x)
            % Try ISO-8601 first, then generic parse
            try
                x = datetime(x, 'InputFormat',"yyyy-MM-dd'T'HH:mm:ss.SSS", 'TimeZone','local');
            catch
                x = datetime(x, 'TimeZone','local');
            end
        end
        if ~isempty(x) && ~isempty(x.TimeZone)
            x.TimeZone = '';           % make tz-naive
        end
        T.(v{1}) = x;
    end
end

function key = buildCompositeKey(T, keyCols, fmt)
% Build a row-wise composite key, formatting datetimes with a robust fmt.
% Example fmt: "yyyyMMdd'T'HHmmss.SSS"
    if nargin < 3 || strlength(fmt)==0
        fmt = "yyyyMMdd'T'HHmmss.SSS";
    else
        fmt = string(fmt);
    end
    if isempty(T); key = strings(0,1); return; end

    parts = strings(height(T), numel(keyCols));
    for k = 1:numel(keyCols)
        col = keyCols{k};
        v   = T.(col);
        if isdatetime(v)
            if ~isempty(v) && ~isempty(v.TimeZone)
                v.TimeZone = '';
            end
            s = string(v, fmt);        % correct tokens & quoted 'T'
            s(ismissing(s)) = "NaT";
            parts(:,k) = s;
        else
            s = string(v);
            s(ismissing(s)) = "<missing>";
            parts(:,k) = s;
        end
    end
    key = join(parts, "|", 2);
    key = key(:,1);
end

function t2 = roundDatetime(t, tol)
    if isempty(t), t2 = t; return; end
    s  = seconds(tol);
    p  = posixtime(t);                   % NaT → NaN
    pr = round(p / s) * s;               % NaN stays NaN
    t2 = datetime(pr, 'ConvertFrom','posixtime');
end

function [A, B] = alignSchemas(A, B)
    namesA   = A.Properties.VariableNames;
    namesB   = B.Properties.VariableNames;
    allNames = unique([namesA, namesB], 'stable');

    missA = setdiff(allNames, namesA);
    for i = 1:numel(missA)
        v = missA{i};
        A.(v) = defaultColumnLike(B.(v), height(A));
    end

    missB = setdiff(allNames, namesB);
    for i = 1:numel(missB)
        v = missB{i};
        B.(v) = defaultColumnLike(A.(v), height(B));
    end

    A = A(:, allNames);
    B = B(:, allNames);
end

function col = defaultColumnLike(sample, m)
    % Create a default column of the same "kind" as sample, length m.
    if isempty(sample)
        col = strings(m,1);
        return
    end
    switch class(sample)
        case {'double','single','int8','uint8','int16','uint16','int32','uint32','int64','uint64'}
            col = cast(nan(m,1), 'like', sample);
        case 'logical'
            col = false(m,1);
        case 'datetime'
            col = NaT(m,1);
        case 'duration'
            col = seconds(nan(m,1));
        case {'string','char'}
            col = strings(m,1);
        case 'cell'
            col = cell(m,1);
        case 'categorical'
            col = categorical(repmat(missing, m,1), categories(sample), 'Ordinal', isordinal(sample));
        otherwise
            try
                col = repmat(missing, m, 1);
            catch
                col = repmat({[]}, m, 1);
            end
    end
end

function writePerFolderMasters(T, groupVar, pattern, writeCSV)
    grp = string(T.(groupVar));
    keys = unique(grp);
    for k = 1:numel(keys)
        folderKey = keys(k);
        if strlength(folderKey)==0 || folderKey == ""; continue; end
        mask = (grp == folderKey);
        PerFolder_Master = T(mask, :); %#ok<NASGU>
        save(sprintf(pattern, folderKey), 'PerFolder_Master', '-v7.3');
        if writeCSV
            try
                writetable(T(mask, :), sprintf(replace(pattern, '.mat', '.csv'), folderKey));
            catch ME
                warning('update_brake_master:CSVFolder','CSV write failed for %s: %s', folderKey, ME.message);
            end
        end
    end
end
