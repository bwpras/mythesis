clear; clc; close all;

parentDir = uigetdir(pwd, 'Select parent folder containing Dati folders');
if parentDir == 0
    disp('No folder selected.');
    return;
end

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
        [lat, lon, spd, count, rpm, Ibatt, Vbatt, payload, ts] = read_pjm_file(fname);
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
excelFile = fullfile(parentDir, 'Wagon_Summary.xlsx');
if exist(excelFile, 'file')
    delete(excelFile);   % wipes old sheets/rows
end
writetable(T, excelFile, 'Sheet','Summary');  % fresh file, clean sheet

%% Grouping Traveling Event

% Only keep moving events
MovingSummary = Summary(Summary.IsMoving == true,:);
excelFile = fullfile(parentDir, 'Wagon_Travel_Summary.xlsx');
if exist(excelFile, 'file')
    delete(excelFile);   % wipes old sheets/rows
end
writetable(MovingSummary, excelFile, 'Sheet','Travel_Summary');  % fresh file, clean sheet

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
save('MovingSummary.mat', 'MovingSummary')
%% Group by Folder × Date (+1 day)
GroupedEvents = table();
groupCounter = 0;

folders = unique(MovingSummary.Folder);

for f = 1:length(folders)
    folderName = folders(f);
    rows = MovingSummary(strcmp(MovingSummary.Folder, folderName), :);
    rows = sortrows(rows, 'StartTime'); 
    uniqueDates = unique(rows.Date);

    for d = 1:length(uniqueDates)
        dayDate = uniqueDates(d);
        startT = dayDate;            % start at 00:00 of Date
        endT   = dayDate + days(1);  % extend +1 day

        groupCounter = groupCounter + 1;
        GroupedEvents(groupCounter,:) = {folderName, ...
            rows.SensorType(1), rows.Wagon(1), ...
            startT, endT, false};  % HasPressure default = false
    end
end

GroupedEvents.Properties.VariableNames = {'Folder','SensorType','Wagon','StartTime','EndTime','HasPressure'};

% Check for _p.bin files in each window
for g = 1:height(GroupedEvents)
    folderPath = fullfile(parentDir, GroupedEvents.Folder{g});
    sensorType = GroupedEvents.SensorType{g};
    if strcmp(sensorType,'HP')
        FCAMP = 40;
    else
        FCAMP = 1.62181;
    end

    % List pressure files in folder
    pFiles = dir(fullfile(folderPath, '*_p.bin'));
    if isempty(pFiles)
        continue; % no pressure files in this folder
    end

    % Event window
    eventStart = GroupedEvents.StartTime(g);
    eventEnd   = GroupedEvents.EndTime(g);

    for k = 1:numel(pFiles)
        pfile = fullfile(pFiles(k).folder, pFiles(k).name);

        try
            % Simple timestamp read from filename (YYYY_MMDDHHMMSS)
            tokens = regexp(pFiles(k).name, '(\d{4})_(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})', 'tokens', 'once');
            if isempty(tokens), continue; end
            ts_file = datetime(str2double(tokens{1}), str2double(tokens{2}), str2double(tokens{3}), ...
                str2double(tokens{4}), str2double(tokens{5}), str2double(tokens{6}));

            if ts_file >= eventStart && ts_file <= eventEnd
                GroupedEvents.HasPressure(g) = true;
                break;
            end
        catch
            fprintf('Error parsing %s\n', pfile);
        end
    end
end

%% Final result
disp(GroupedEvents);
excelFile = fullfile(parentDir, 'Wagon_PressureData.xlsx');
if exist(excelFile, 'file')
    delete(excelFile);   % wipes old sheets/rows
end
writetable(GroupedEvents, excelFile, 'Sheet','Grouped_PressureData');  % fresh file, clean sheet
input('Press Enter to continue','s');
%% Build Nodo Struct (using MovingSummary + 1-hour windows from Date)
% Requirements:
% - SensorMap and parentDir already defined
% - MovingSummary contains columns: Folder (char or string), Date (datetime), HasPressure (logical)

MSG_WAKE = 0x20;   % 0x20
AllNodo  = struct();

% Use only the rows that have pressure
EventRows = MovingSummary(MovingSummary.HasPressure == true, :);

% Folders we need to process
folders = unique(EventRows.Folder);

for f = 1:numel(folders)
    folderName = folders(f);
    folderNameChar = char(folderName);
    folderPath = fullfile(parentDir, folderNameChar);

    fprintf('Processing folder: %s\n', folderNameChar);

    % FCAMP from SensorMap
    if isKey(SensorMap, folderNameChar) && strcmp(SensorMap(folderNameChar), 'HP')
        FCAMP = 40;
    else
        FCAMP = 1.62181;
    end

    % ---- Cache all *_p.bin files in this folder once, parse their filename times
    pFiles = dir(fullfile(folderPath, '*_p.bin'));
    pTimes = NaT(numel(pFiles),1);
    for kk = 1:numel(pFiles)
        nm = pFiles(kk).name;
        t = regexp(nm, '^(\d{4})_(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})', 'tokens', 'once');
        if ~isempty(t)
            pTimes(kk) = datetime(str2double(t{1}), str2double(t{2}), str2double(t{3}), ...
                                  str2double(t{4}), str2double(t{5}), str2double(t{6}));
        end
    end
    good = ~isnat(pTimes);
    pFiles = pFiles(good);
    pTimes = pTimes(good);

    % Per-folder containers
    nodo_Press = containers.Map;
    nodo_Time = containers.Map;
    nodo_Vbatt = containers.Map;
    nodo_Vin = containers.Map;
    nodo_Id = containers.Map;
    nodo_Ic = containers.Map;
    nodo_Temp = containers.Map;
    nodo_RSSI = containers.Map;
    nodo_Start_time = containers.Map;
    nodo_MSG_WAKE = containers.Map;
    nodo_cont_pkt = containers.Map;
    nodo_end_time = containers.Map;

    % ---- Loop over 1-hour windows from MovingSummary.Date
    folderRows = EventRows(strcmp(EventRows.Folder, folderName), :);

    for e = 1:height(folderRows)
        fileDate = folderRows.Date(e);
        if isnat(fileDate), continue; end

        eventStart = fileDate;
        eventEnd   = fileDate + hours(1);    % end-exclusive recommended

        % Select pressure files whose filename time is inside [eventStart, eventEnd)
        mask = (pTimes >= eventStart) & (pTimes < eventEnd);
        if ~any(mask), continue; end

        theseFiles = pFiles(mask);
        theseTimes = pTimes(mask);   % "end_time" per file from filename

        for h = 1:numel(theseFiles)
            nomefile = fullfile(theseFiles(h).folder, theseFiles(h).name);
            end_time = theseTimes(h);
            fprintf('  Reading P: %s\n', theseFiles(h).name);

            fpi = fopen(nomefile, 'r');
            if fpi < 0
                warning('Cannot open %s', nomefile);
                continue;
            end
            cleanupObj = onCleanup(@() fclose(fpi));

            cont_MSG_WAKE = 0;
            cont_pkt = 0;

            % node id from filename: 2025_0601190000_0xXX_p.bin
            pp = strsplit(theseFiles(h).name, '_');
            if numel(pp) < 3, continue; end
            nodeID = pp{3};  % e.g., '0x00'

            while ~feof(fpi)
                sohcar   = fread(fpi,1,'uint8');
                contatore= fread(fpi,1,'uint8');
                pktlen   = fread(fpi,1,'uint8');
                idDest   = fread(fpi,1,'uint8');
                idSource = fread(fpi,1,'uint8');
                PkType   = fread(fpi,1,'uint8');
                if isempty(PkType), break; end

                if PkType == MSG_WAKE
                    cont_MSG_WAKE = cont_MSG_WAKE + 1;
                    Soglia = fread(fpi,1,'uint8');
                    Vbatt  = fread(fpi,1,'uint16')/1000;
                    Vin    = fread(fpi,1,'uint16')/1000;
                    Id     = fread(fpi,1,'uint16')*0.1;
                    Ic     = fread(fpi,1,'uint16')*0.1;
                    Temp   = fread(fpi,1,'int16')*0.01;
                    RSSI   = -(256 - fread(fpi,1,'uint8'));
                    eochar = fread(fpi,1,'uint8');
                    % metadata only
                else
                    cont_pkt = cont_pkt + 1;

                    Vbatt = fread(fpi,1,'uint16')/1000;
                    Vin   = fread(fpi,1,'uint16')/1000;
                    Id    = fread(fpi,1,'uint16')*0.1;
                    Ic    = fread(fpi,1,'uint16')*0.1;
                    Temp  = fread(fpi,1,'int16')*0.01;

                    % timestamp (ms since epoch)
                    Ts_ms = fread(fpi,1,'uint64');
                    Start_time_pkt = datetime(double(Ts_ms)/1000, 'ConvertFrom','posixtime');

                    if FCAMP == 40
                        Press = fread(fpi,80,'int16')';
                        Time_row = Start_time_pkt + seconds((0:79)/FCAMP);
                    else
                        FCAMP_LP = 1.62181;
                        Press = fread(fpi,10,'int16')';
                        Time_row = Start_time_pkt + seconds((0:9)/FCAMP_LP);
                        fread(fpi,70,'int16');   % skip filler zeros
                    end

                    n_sample = fread(fpi,1,'uint16');
                    dummy1   = fread(fpi,1,'uint16');
                    dummy2   = fread(fpi,1,'uint16');
                    RSSI     = -(256 - fread(fpi,1,'uint8'));
                    eochar   = fread(fpi,1,'uint8');

                    % ---- Append to maps (per nodeID)
                    if isKey(nodo_Press, nodeID)
                        nodo_Press(nodeID)      = [nodo_Press(nodeID); Press(:)];
                        nodo_Time(nodeID)       = [nodo_Time(nodeID), Time_row];
                        nodo_Vbatt(nodeID)      = [nodo_Vbatt(nodeID), Vbatt];
                        nodo_Vin(nodeID)        = [nodo_Vin(nodeID),   Vin];
                        nodo_Id(nodeID)         = [nodo_Id(nodeID),    Id];
                        nodo_Ic(nodeID)         = [nodo_Ic(nodeID),    Ic];
                        nodo_Temp(nodeID)       = [nodo_Temp(nodeID),  Temp];
                        nodo_RSSI(nodeID)       = [nodo_RSSI(nodeID),  RSSI];
                        nodo_Start_time(nodeID) = [nodo_Start_time(nodeID), Start_time_pkt];
                        nodo_MSG_WAKE(nodeID)   = cont_MSG_WAKE;
                        nodo_cont_pkt(nodeID)   = cont_pkt;
                    else
                        nodo_Press(nodeID)      = Press(:);
                        nodo_Time(nodeID)       = Time_row;
                        nodo_Vbatt(nodeID)      = Vbatt;
                        nodo_Vin(nodeID)        = Vin;
                        nodo_Id(nodeID)         = Id;
                        nodo_Ic(nodeID)         = Ic;
                        nodo_Temp(nodeID)       = Temp;
                        nodo_RSSI(nodeID)       = RSSI;
                        nodo_Start_time(nodeID) = Start_time_pkt;
                        nodo_MSG_WAKE(nodeID)   = cont_MSG_WAKE;
                        nodo_cont_pkt(nodeID)   = cont_pkt;
                        nodo_end_time(nodeID)   = end_time;  % from filename
                    end
                end
            end % while
        end % files in window
    end % 1-hour windows for this folder

    % ---- Build Nodo struct for this folder
    kk = keys(nodo_Press);
    n_nodi = numel(kk);
    Nodo = repmat(struct('ID',[],'Time',[],'Pressure',[],...
                         'Vbatt',[],'Vin',[],'Id',[],'Ic',[],...
                         'Temperature',[],'RSSI',[],'Start_time',[]), 1, n_nodi);

    for ff = 1:n_nodi
        id = kk{ff};
        Nodo(ff).ID = id;
        Nodo(ff).Time = nodo_Time(id);                     % row datetime array
        pCal = ((double(nodo_Press(id)) * 3.6 / 3.3) * 0.000788) - 2.3057;
        Nodo(ff).Pressure = pCal.';                        % row to match Time
        Nodo(ff).Vbatt = nodo_Vbatt(id);
        Nodo(ff).Vin   = nodo_Vin(id);
        Nodo(ff).Id    = nodo_Id(id);
        Nodo(ff).Ic    = nodo_Ic(id);
        Nodo(ff).Temperature = nodo_Temp(id);
        Nodo(ff).RSSI  = nodo_RSSI(id);
        Nodo(ff).Start_time = nodo_Start_time(id);
    end

    AllNodo.(folderNameChar) = Nodo;
end

%%
folderNames = fieldnames(AllNodo);
seenIDs = {};  % track globally encountered IDs

for f = 1:numel(folderNames)
    folder = folderNames{f};
    NodoArray = AllNodo.(folder);

    if isempty(NodoArray)
        continue;
    end

    keepIdx = true(1, numel(NodoArray));
    for i = 1:numel(NodoArray)
        id = NodoArray(i).ID;
        if ismember(id, seenIDs)
            % already seen in an earlier folder → skip this one
            keepIdx(i) = false;
        else
            % first time we see this ID → keep it
            seenIDs{end+1} = id; 
        end
    end

    % Keep only non-duplicate nodes
    AllNodo.(folder) = NodoArray(keepIdx);

    fprintf('Cleaned %s: kept %d unique nodes out of %d\n', ...
        folder, sum(keepIdx), numel(NodoArray));
end

%% Parameters
% Define date limits
minDate = datetime(2025,1,1);
maxDate = datetime(2027,1,1);

folderNames = fieldnames(AllNodo);

for f = 1:numel(folderNames)
    folder = folderNames{f};
    NodoArray = AllNodo.(folder);

    if isempty(NodoArray)
        continue;
    end

    for i = 1:numel(NodoArray)
        n = NodoArray(i);

        % Filter packet-level fields using Start_time
        pktIdx = (n.Start_time >= minDate) & (n.Start_time < maxDate);
        n.Start_time  = n.Start_time(pktIdx);
        n.Vbatt       = n.Vbatt(pktIdx);
        n.Vin         = n.Vin(pktIdx);
        n.Id          = n.Id(pktIdx);
        n.Ic          = n.Ic(pktIdx);
        n.Temperature = n.Temperature(pktIdx);
        n.RSSI        = n.RSSI(pktIdx);

        % Filter high-frequency fields using Time
        sampleIdx = (n.Time >= minDate) & (n.Time < maxDate);
        n.Time     = n.Time(sampleIdx);
        n.Pressure = n.Pressure(sampleIdx);

        % Write back
        NodoArray(i) = n;
    end

    % Save filtered back into AllNodo
    AllNodo.(folder) = NodoArray;
end

%% Add PJM data (read exactly the files listed in MovingSummary with HasPressure=true)
EventRows = MovingSummary(MovingSummary.HasPressure == true, :);

folderNames = fieldnames(AllNodo);
for f = 1:numel(folderNames)
    folder = folderNames{f};
    if ~isfield(AllNodo, folder) || isempty(AllNodo.(folder)), continue; end
    NodoArray = AllNodo.(folder);

    % Rows for this folder
    rowsF = EventRows(strcmp(EventRows.Folder, folder), :);
    if isempty(rowsF)
        % ensure GPS fields exist (empty) to avoid checks later
        for i = 1:numel(NodoArray)
            NodoArray(i).GPS_Lat   = [];
            NodoArray(i).GPS_Lon   = [];
            NodoArray(i).GPS_Speed = [];
            NodoArray(i).GPS_RPM   = [];
            NodoArray(i).GPS_Ibatt = [];
            NodoArray(i).GPS_Vbatt = [];
            NodoArray(i).Time_GPS  = [];
        end
        AllNodo.(folder) = NodoArray;
        continue;
    end

    % Use unique filenames from MovingSummary
    pjFiles = unique(rowsF.Filename);

    GPS_lat = []; GPS_lon = [];
    GPS_speed = []; GPS_rpm = [];
    GPS_Ibatt = []; GPS_Vbatt = [];
    Time_GPS = [];

    for k = 1:numel(pjFiles)
        fname = pjFiles{k};
        fullpath = fullfile(parentDir, folder, fname);
        if ~isfile(fullpath)
            warning('PJM file not found: %s', fullpath);
            continue;
        end

        % Read PJM once, no time filtering
        [lat, lon, spd, count, rpm_k, Ibatt_k, Vbatt_k, payload_k, ts] = ...
            read_pjm_file(fullpath); 

        % Keep valid GPS only
        valid = (lat ~= 0) & (lon ~= 0);
        if any(valid)
            GPS_lat   = [GPS_lat,   lat(valid)];
            GPS_lon   = [GPS_lon,   lon(valid)];
            GPS_speed = [GPS_speed, spd(valid)];
            GPS_rpm   = [GPS_rpm,   rpm_k(valid)];
            GPS_Ibatt = [GPS_Ibatt, Ibatt_k(valid)];
            GPS_Vbatt = [GPS_Vbatt, Vbatt_k(valid)];
            Time_GPS  = [Time_GPS,  ts(valid)];
        end
    end

    % (Optional) remove duplicate by timestamp if the same file appears twice
    if ~isempty(Time_GPS)
        [Time_GPS, jj] = unique(Time_GPS, 'stable');
        GPS_lat   = GPS_lat(jj);
        GPS_lon   = GPS_lon(jj);
        GPS_speed = GPS_speed(jj);
        GPS_rpm   = GPS_rpm(jj);
        GPS_Ibatt = GPS_Ibatt(jj);
        GPS_Vbatt = GPS_Vbatt(jj);
    end

    % Attach the collected GPS to every node in this folder
    for i = 1:numel(NodoArray)
        NodoArray(i).GPS_Lat   = GPS_lat;
        NodoArray(i).GPS_Lon   = GPS_lon;
        NodoArray(i).GPS_Speed = GPS_speed;
        NodoArray(i).GPS_RPM   = GPS_rpm;
        NodoArray(i).GPS_Ibatt = GPS_Ibatt;
        NodoArray(i).GPS_Vbatt = GPS_Vbatt;
        NodoArray(i).Time_GPS  = Time_GPS;
    end

    AllNodo.(folder) = NodoArray;
end

%% Export Nodo by 1-hour windows defined in MovingSummary.Date
outDir = fullfile(pwd, 'DataExtraction');
if ~exist(outDir, 'dir'), mkdir(outDir); end

% Use only rows where we actually searched for/found pressure
% EventRows = MovingSummary(MovingSummary.HasPressure == true, :);

folderNames = fieldnames(AllNodo);
for f = 1:numel(folderNames)
    folder = folderNames{f};
    if ~isfield(AllNodo, folder) || isempty(AllNodo.(folder)), continue; end
    NodoArray = AllNodo.(folder);

    % Windows for this folder: 1 row = 1 hour window [Date, Date+1h)
    folderRows = EventRows(strcmp(EventRows.Folder, folder), :);
    if isempty(folderRows), continue; end

    for e = 1:height(folderRows)
        tStart = folderRows.Date(e);
        if isnat(tStart), continue; end
        tEnd   = tStart + hours(1);   % end-exclusive

        NodoBit = [];
        for i = 1:numel(NodoArray)
            n = NodoArray(i);

            % --- Filter packet-level fields (Start_time) ---
            pktIdx = (n.Start_time >= tStart) & (n.Start_time < tEnd);

            % --- Filter high-frequency fields (Time/Pressure) ---
            sampleIdx = (n.Time >= tStart) & (n.Time < tEnd);

            % --- Filter GPS fields ---
            % gpsIdx = (n.Time_GPS >= tStart) & (n.Time_GPS < tEnd);
            gpsIdx = true(size(n.Time_GPS));  % don't slice GPS by window

            if any(pktIdx) || any(sampleIdx) || any(gpsIdx)
                newN = n;

                % Packet-level fields
                newN.Start_time  = n.Start_time(pktIdx);
                newN.Vbatt       = n.Vbatt(pktIdx);
                newN.Vin         = n.Vin(pktIdx);
                newN.Id          = n.Id(pktIdx);
                newN.Ic          = n.Ic(pktIdx);
                newN.Temperature = n.Temperature(pktIdx);
                newN.RSSI        = n.RSSI(pktIdx);

                % High-frequency fields
                newN.Time        = n.Time(sampleIdx);
                newN.Pressure    = n.Pressure(sampleIdx);

                % GPS fields (only if present)
                if isfield(n,'Time_GPS')
                    newN.Time_GPS    = n.Time_GPS(gpsIdx);
                    newN.GPS_Lat     = n.GPS_Lat(gpsIdx);
                    newN.GPS_Lon     = n.GPS_Lon(gpsIdx);
                    newN.GPS_Speed   = n.GPS_Speed(gpsIdx);
                    newN.GPS_RPM     = n.GPS_RPM(gpsIdx);
                    newN.GPS_Vbatt   = n.GPS_Vbatt(gpsIdx);
                    newN.GPS_Ibatt   = n.GPS_Ibatt(gpsIdx);
                end

                NodoBit = [NodoBit, newN];
            end
        end

        % Save this 1-hour chunk if not empty
        if ~isempty(NodoBit)
            fname = sprintf('%s_%s_to_%s.mat', folder, ...
                datestr(tStart,'yyyymmdd_HHMM'), datestr(tEnd,'yyyymmdd_HHMM'));
            save(fullfile(outDir,fname), 'NodoBit', '-v7.3');  % <- save the right var
            fprintf('Saved %s with %d nodes\n', fname, numel(NodoBit));
        end
    end
end
