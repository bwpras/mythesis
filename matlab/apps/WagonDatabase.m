function MovingSummary = WagonDatabase()
% buildMovingSummary  Process all Dati folders and produce Summary + MovingSummary
% Usage:
%   [Summary, MovingSummary] = utils.buildMovingSummary('data','output');
paths = startup();
parentDir = paths.root;
outDir    = paths.reports;

%% Sensor mapping (KIT → SensorType + Wagon)
KitNumbers = 1:35;

SensorTypes = { ...
    'HP','LP','HP','HP','HP','HP','LP','LP','LP', ...
    'HP','HP','HP','LP','HP','LP','LP','LP','HP', ...
    'LP','LP','LP','LP','LP','HP','HP','HP','HP','LP', ...
    'LP','LP','LP','HP','HP','HP','LP'};

Wagons = { ...
    'T3000','4575','4909','T3000','4575','T3000','T3000','T3000','T3000', ...
    '4909','4909','4909','T3000','4575','4575','4909','4909','4909', ...
    '4909','4909','4909','4909','4909','4909','T3000','T3000','T3000', ...
    'T3000','T3000','T3000','T3000','4575','4575','4575','4575'};

SensorMap = containers.Map;
WagonMap  = containers.Map;
for i = 1:numel(KitNumbers)
    folderName = sprintf('Dati%02d', KitNumbers(i));
    SensorMap(folderName) = SensorTypes{i};
    WagonMap(folderName)  = Wagons{i};
end

%% Initialize summary table with extra columns (add InvalidTimestampCount)
Summary = table('Size',[0 33], ...
    'VariableTypes',{'string','string','string','string', ...
    'datetime','datetime','datetime','logical', ...
    'double','double','double', ...
    'double','double','double', ...
    'double','double','double', ...
    'double','double','double','double','double', ...
    'double','double','double', ...
    'duration','double','double', ...
    'double','double','double','double', ...
    'double'}, ...  % <-- InvalidTimestampCount
    'VariableNames',{'Folder','SensorType','Wagon','Filename', ...
    'Date','StartTime','EndTime','IsMoving', ...
    'MaxSpeed','AvgSpeed','TotalDistance_km', ...
    'StartLat','StartLon','StartSpeed', ...
    'EndLat','EndLon','EndSpeed', ...
    'StartVbatt','EndVbatt','StartIbatt','EndIbatt','MsgsCount', ...
    'InvalidGPSCount','RPM0Count','RPM308Count', ...
    'AcqPeriod','RawFreq','NominalFreq', ...
    'GapCount','MaxGap','GapRatio','AvgGap', ...
    'InvalidTimestampCount'});   % <-- new column

subFolders = dir(fullfile(parentDir, 'Dati*'));
for f = 1:length(subFolders)
    folderName = subFolders(f).name;
    folderPath = fullfile(parentDir, folderName);

    if ~isKey(SensorMap, folderName)
        fprintf('Skipping %s (no sensor mapping)\n', folderName);
        continue;
    end

    listafile_pjm = dir(fullfile(folderPath, '*pjm.bin'));

    for k = 1:length(listafile_pjm)
        fname = fullfile(folderPath, listafile_pjm(k).name);
        fprintf('Reading: %s\n', fname);

        % Read the PJM file
        [lat, lon, spd, count, rpm, Ibatt, Vbatt, ~, ts] = read_pjm_file39(fname);
        % --- Diagnostics counts BEFORE filtering ---
        invalidGPSCount = sum(lat == 0 | lon == 0);
        rpm0Count       = sum(rpm == 0);
        rpm308Count     = sum(rpm == 308);

        % --- Gap metrics (unchanged) ---
        gapThreshold = 5; % seconds
        if numel(ts) > 1
            dt = seconds(diff(ts));
            gapCount = sum(dt > gapThreshold);
            if gapCount > 0
                maxGap  = max(dt(dt > gapThreshold));
                avgGap  = mean(dt(dt > gapThreshold));
                gapRatio = (gapCount / (numel(ts)-1)) * 100;
            else
                maxGap  = 0;
                avgGap  = 0;
                gapRatio = 0;
            end
        else
            gapCount = 0; maxGap = 0; avgGap = 0; gapRatio = 0;
        end

        % Filter only invalid lat/lon for movement/dist calc
        valid_idx = (lat ~= 0 & lon ~= 0);
        lat   = lat(valid_idx);
        lon   = lon(valid_idx);
        spd   = spd(valid_idx);
        ts    = ts(valid_idx);
        rpm   = rpm(valid_idx);
        Ibatt = Ibatt(valid_idx);
        Vbatt = Vbatt(valid_idx);

        if isempty(lat)
            continue;
        end

        validYearMin = 2025;   % adjust if needed
        validYearMax = 2027;

        invalidTsMask = isnat(ts) | year(ts) < validYearMin | year(ts) > validYearMax;
        invalidTimestampCount = sum(invalidTsMask);

        validTs = ts(~invalidTsMask);

        if isempty(validTs)
            % No valid timestamps → set NaT but keep the row
            startT = NaT;
            endT   = NaT;
        else
            % First/last valid timestamps (+2h offset)
            startT = validTs(1) + hours(2);
            endT   = validTs(end) + hours(2);
        end
        % ---------- Movement / distance ----------
        R = 6371; % km
        dLat = deg2rad(diff(lat));
        dLon = deg2rad(diff(lon));
        a = sin(dLat/2).^2 + cosd(lat(1:end-1)).*cosd(lat(2:end)).*sin(dLon/2).^2;
        c = 2*atan2(sqrt(a), sqrt(1-a));
        totalDist = sum(R*c);

        maxSpd = max(spd);
        avgSpd = mean(spd);
        isMoving = maxSpd > 20;

        startLat = lat(1); startLon = lon(1); startSpd = spd(1);
        endLat   = lat(end); endLon = lon(end); endSpd = spd(end);
        startVbatt = Vbatt(1); endVbatt = Vbatt(end);
        startIbatt = Ibatt(1); endIbatt = Ibatt(end);

        % Sensor/Wagon
        sensorType = SensorMap(folderName);
        wagonType  = WagonMap(folderName);

        % ----- Acquisition period & frequency (with guard) -----
        MaxAcqHours = 12;  % adjust as needed

        if isnat(startT) || isnat(endT)
            acqPeriod = seconds(NaN);   % missing duration
            rawFreq   = NaN;
        else
            acqPeriod = endT - startT;  % duration
            if acqPeriod < seconds(0) || acqPeriod > hours(MaxAcqHours)
                % nonsensical or too large -> treat as invalid
                acqPeriod = seconds(NaN);
                rawFreq   = NaN;
            else
                % Raw frequency = raw message count / period (in seconds)
                rawFreq = count / seconds(acqPeriod);
            end
        end

        % Nominal frequency (unchanged)
        if numel(ts) > 1
            dt = seconds(diff(ts));
            valid_dt = dt(dt > 0 & dt < 3);
            nominalFreq = ~isempty(valid_dt) * (1/median(valid_dt));
            if nominalFreq == 0, nominalFreq = NaN; end
        else
            nominalFreq = NaN;
        end
        msgsCount = count;

        % ---- Parse Date from filename (YYYY_MMDDHHMMSS...) ----
        baseName = listafile_pjm(k).name;
        % Robust regex: grab 4-digit year, underscore, then 10 digits (MMDDHHMMSS)
        m = regexp(baseName, '^(?<Y>\d{4})_(?<T>\d{10})', 'names');

        if ~isempty(m)
            yr = str2double(m.Y);
            s  = m.T;  % 'MMDDHHMMSS'
            mo = str2double(s(1:2));
            dy = str2double(s(3:4));
            hh = str2double(s(5:6));
            mmn= str2double(s(7:8));
            ss = str2double(s(9:10));

            % If you want local time semantics, you can set a timezone:
            % fileDate = datetime(yr,mo,dy,hh,mmn,ss,'TimeZone','Europe/Rome');
            fileDate = datetime(yr,mo,dy,hh,mmn,ss);  % naive datetime
        else
            % Fallback if the filename doesn't match expected pattern
            fileDate = startT;   % or NaT; pick your preferred fallback
        end
        % ---------- Append to Summary (now includes InvalidTimestampCount) ----------
        Summary = [Summary; {folderName, sensorType, wagonType, listafile_pjm(k).name, ...
            fileDate, startT, endT, isMoving, ...
            maxSpd, avgSpd, totalDist, ...
            startLat, startLon, startSpd, ...
            endLat, endLon, endSpd, ...
            startVbatt, endVbatt, startIbatt, endIbatt, ...
            msgsCount, invalidGPSCount, rpm0Count, rpm308Count, ...
            acqPeriod, rawFreq, nominalFreq, ...
            gapCount, maxGap, gapRatio, avgGap, ...
            invalidTimestampCount}];   % <-- new value
    end
end

% Define valid date range for StartTime flag
minDate = datetime(2025,1,1);
maxDate = datetime(2027,1,1);

Summary.InvalidDateFlag = zeros(height(Summary),1);
for r = 1:height(Summary)
    s = Summary.StartTime(r);
    e = Summary.EndTime(r);

    if (isnat(s) || s < minDate || s >= maxDate) || ...
            (isnat(e) || e < minDate || e >= maxDate)
        Summary.InvalidDateFlag(r) = 1; % invalid if start OR end bad
    else
        Summary.InvalidDateFlag(r) = 0; % both start & end valid
    end
end
%%
T = Summary;

for c = 1:width(T)
    if isdatetime(T.(c))
        natMask = isnat(T.(c));
        T.(c) = cellstr(datestr(T.(c), 'yyyy-mm-dd HH:MM:SS'));
        T.(c)(natMask) = {''};
    elseif isduration(T.(c))
        % treat missing durations (NaN seconds) as blank
        d = seconds(T.(c));                 % numeric seconds (NaN for missing)
        str = strings(height(T),1);
        ok  = ~isnan(d);
        str(ok) = string(T.(c)(ok));        % e.g., "00:12:34"
        str(~ok) = "";                      % blanks for missing
        T.(c) = cellstr(str);
    end
end
% excelFile = fullfile(parentDir, 'Wagon_Summary.xlsx');
% if exist(excelFile, 'file')
%     delete(excelFile);   % wipes old sheets/rows
% end
% writetable(T, excelFile, 'Sheet','Summary');  % fresh file, clean sheet

%% Grouping Traveling Event

% Only keep moving events
MovingSummary = Summary(Summary.IsMoving == true,:);
% excelFile = fullfile(parentDir, 'Wagon_Travel_Summary.xlsx');
% if exist(excelFile, 'file')
%     delete(excelFile);   % wipes old sheets/rows
% end
% writetable(MovingSummary, excelFile, 'Sheet','Travel_Summary');  % fresh file, clean sheet

%% Pressure-file detection using 1-hour windows starting at MovingSummary.Date

% Ensure columns exist
if ~ismember('HasPressure', MovingSummary.Properties.VariableNames)
    MovingSummary.HasPressure = false(height(MovingSummary), 1);
end
if ~ismember('NumPressureFiles', MovingSummary.Properties.VariableNames)
    MovingSummary.NumPressureFiles = zeros(height(MovingSummary), 1);
end

% Parameters
WindowHours = 1;                      % 1-hour window [start, start+1h)
timeEndIsExclusive = true;            % use end-exclusive to avoid double-count across adjacent rows

% Timezone handling: keep pressure times consistent with MovingSummary.Date
dateTZ = '';
if isdatetime(MovingSummary.Date) && ~isempty(MovingSummary.Date.TimeZone)
    dateTZ = MovingSummary.Date.TimeZone;
end

% Cache pressure file timestamps per folder to avoid repeated dir/regex work
pTimesCache = containers.Map('KeyType','char','ValueType','any');

% Helper: parse timestamp from pressure filename "YYYY_MMDDHHMMSS_..."
parsePfileTime = @(nm) ...
    (function_handle(@() 0)); %#ok<NASGU> % dummy line to allow block function
    function dt = parsePfileTime_inner(nm, dateTZ)
        t = regexp(nm, '^(\d{4})_(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})', 'tokens', 'once');
        if isempty(t)
            dt = NaT; return;
        end
        yr = str2double(t{1}); mo = str2double(t{2}); dy = str2double(t{3});
        hh = str2double(t{4}); mm = str2double(t{5}); ss = str2double(t{6});
        if isempty(dateTZ)
            dt = datetime(yr,mo,dy,hh,mm,ss);
        else
            dt = datetime(yr,mo,dy,hh,mm,ss, 'TimeZone', dateTZ);
        end
    end
parsePfileTime = @(nm) parsePfileTime_inner(nm, dateTZ);

% Build list of unique folders we need to scan
uFolders = unique(MovingSummary.Folder);

% Populate cache
for i = 1:numel(uFolders)
    folderName = uFolders{i};
    folderPath = fullfile(parentDir, folderName);
    pFiles = dir(fullfile(folderPath, '*_p.bin'));
    if isempty(pFiles)
        pTimesCache(folderName) = datetime.empty(0,1);
        continue;
    end
    pTimes = NaT(numel(pFiles),1);
    for k = 1:numel(pFiles)
        pTimes(k) = parsePfileTime(pFiles(k).name);
    end
    % Drop any NaT parses
    pTimes = pTimes(~isnat(pTimes));
    pTimesCache(folderName) = pTimes;
end

% Scan each MovingSummary row with a 1-hour window
for r = 1:height(MovingSummary)
    folderName = MovingSummary.Folder{r};
    % Start of window from filename-derived Date
    fileDate = MovingSummary.Date(r);
    if isnat(fileDate)
        % cannot decide window without a date; leave counts at 0/false
        continue;
    end
    winStart = fileDate;
    winEnd   = fileDate + hours(WindowHours);

    % Get cached pressure times for this folder
    if ~isKey(pTimesCache, folderName)
        continue;
    end
    pTimes = pTimesCache(folderName);
    if isempty(pTimes)
        continue;
    end

    % Count matches in the window
    if timeEndIsExclusive
        mask = (pTimes >= winStart) & (pTimes <  winEnd);
    else
        mask = (pTimes >= winStart) & (pTimes <= winEnd);
    end

    MovingSummary.NumPressureFiles(r) = nnz(mask);
    MovingSummary.HasPressure(r)      = any(mask);
end

% Save updated table
excelFile = fullfile(parentDir, 'Wagon_Summary_PressureData.xlsx');
writetable(MovingSummary, excelFile, 'Sheet','Summary_withPressure', 'WriteMode','overwritesheet');
save(fullfile(outDir,'MovingSummary.mat'),'MovingSummary');

% Make sure Excel also goes into outDir:
excelFile = fullfile(outDir,'Wagon_Summary.xlsx');
writetable(Summary, excelFile);
return
end

