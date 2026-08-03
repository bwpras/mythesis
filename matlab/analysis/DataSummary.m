clear; clc; close all;

parentDir = uigetdir(pwd, 'Select parent folder containing Dati folders');
if parentDir == 0
    disp('No folder selected.');
    return;
end

%% ====== FAST-PATH CACHE CHECK ============================================
% If MovingSummary.mat exists in parentDir, load it and skip all data reading.
movSumPath = fullfile(parentDir, 'MovingSummary.mat');
useCache   = (exist(movSumPath, 'file') == 2);
useCache = false;
if useCache
    S = load(movSumPath, 'MovingSummary');
    assert(isfield(S,'MovingSummary'), ...
        'MovingSummary.mat exists but does not contain variable ''MovingSummary''.');
    MovingSummary = S.MovingSummary;

    % Basic sanity: make sure the downstream-required vars exist
    needCols = ["Folder","SensorType","Wagon","Date","StartTime","EndTime","IsMoving"];
    missing  = needCols(~ismember(needCols, string(MovingSummary.Properties.VariableNames)));
    assert(isempty(missing), 'Cached MovingSummary is missing columns: %s', strjoin(missing, ', '));

    fprintf('[CACHE] Loaded MovingSummary (%d rows) from %s\n', height(MovingSummary), movSumPath);

else
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
    Summary = table('Size',[0 34], ...
        'VariableTypes',{'string','string','string','string', ...
        'datetime','datetime','datetime','logical', ...
        'double','double','double','double', ...
        'double','double','double', ...
        'double','double','double', ...
        'double','double','double','double','double', ...
        'double','double','double', ...
        'duration','double','double', ...
        'double','double','double','double', ...
        'double'}, ...  % <-- InvalidTimestampCount
        'VariableNames',{'Folder','SensorType','Wagon','Filename', ...
        'Date','StartTime','EndTime','IsMoving', ...
        'MaxSpeed','MaxSpeedRPM','AvgSpeed','TotalDistance_km', ...
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
            [lat, lon, spd, count, rpm, Ibatt, Vbatt, payload, ts] = read_pjm_file39(fname);
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
            speed_rpm = rpm* ((1/60) * 2*pi * 0.92/2 * 3.6);

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
            maxSpd_rpm = max(speed_rpm);
            avgSpd = mean(spd);
            isMoving = maxSpd > 60 || maxSpd_rpm > 60;

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
                maxSpd, maxSpd_rpm, avgSpd, totalDist, ...
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
    excelFile = fullfile(parentDir, 'Database_Summary.xlsx');
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


end

if useCache == false
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
    % disp(GroupedEvents);
    excelFile = fullfile(parentDir, 'Wagon_PressureData.xlsx');
    if exist(excelFile, 'file')
        delete(excelFile);   % wipes old sheets/rows
    end
    writetable(GroupedEvents, excelFile, 'Sheet','Grouped_PressureData');  % fresh file, clean sheet
    save('MovingSummary.mat', 'MovingSummary')
    save('GPSSummary.mat', 'Summary')
    %input('Press Enter to continue','s');
end

       

%% Split into pre September and post September and HP sensor
HP_Data = MovingSummary( ...
    MovingSummary.HasPressure == true & ...
    strcmp(MovingSummary.SensorType, "HP"), :);

% --- 1) Choose a reliable timestamp per row (StartTime > Date > EndTime)
t = HP_Data.StartTime;
bad = isnat(t);
if any(bad)
    t(bad) = HP_Data.Date(bad);
    bad = isnat(t);
    t(bad) = HP_Data.EndTime(bad);
end

% --- 2) Define cutoff(s)
sep1  = datetime(2025,9,1);  % 01-Sep-2025 00:00

% --- 3A) Most common interpretation:
%     "pre September 2025" = before 01-Sep-2025
%     "post September 2025" = on/after 01-Sep-2025 (September included)
HPpreSep2025  = HP_Data(t <  sep1, :);
HPpostSep2025 = HP_Data(t >= sep1, :);

% %%
% clc;
% MS = HPpreSep2025;            % already filtered to IsMoving == true
% mergeGap  = hours(3);          % merge movement intervals separated by <= 3h
% prePad    = hours(6);          % context before movement cluster
% postPad   = hours(6);          % context after movement cluster
% winDur    = hours(24);         % fixed window size
% maxWindowsPerFolder = 4;       % cap per folder (adjust as you like)
% 
% % --- 1) Robust timestamps (tz-naive)
% tS = MS.StartTime;
% bad = isnat(tS);  if any(bad), tS(bad) = MS.Date(bad); end
% bad = isnat(tS);
% tE = MS.EndTime;
% tE(isnat(tE)) = tS(isnat(tE));
% tS(bad) = tE(bad);
% 
% ok = ~isnat(tS) & ~isnat(tE);
% MS = MS(ok,:); tS = tS(ok); tE = tE(ok);
% 
% if strlength(tS.TimeZone) > 0, tS.TimeZone = ""; end
% if strlength(tE.TimeZone) > 0, tE.TimeZone = ""; end
% 
% % --- 2) Prepare accumulators
% Folders = unique(string(MS.Folder));
% allFolders  = strings(0,1);
% allStarts   = datetime.empty(0,1);
% allEnds     = datetime.empty(0,1);
% allRootDirs = strings(0,1);
% 
% for f = 1:numel(Folders)
%     folder = Folders(f);
%     kf = string(MS.Folder) == folder;
% 
%     s = tS(kf); e = tE(kf);
%     keep = (e > s);
%     s = s(keep); e = e(keep);
%     if isempty(s)
%         continue;
%     end
% 
%     % sort by start time
%     [s, ix] = sort(s); e = e(ix);
% 
%     % --- 3) Merge into movement clusters (gap <= mergeGap)
%     cluS = s(1); cluE = e(1);
%     for i = 2:numel(s)
%         if s(i) - cluE(end) <= mergeGap
%             % extend current cluster
%             cluE(end) = max(cluE(end), e(i));
%         else
%             % new cluster
%             cluS(end+1,1) = s(i); 
%             cluE(end+1,1) = e(i); 
%         end
%     end
% 
%     % --- 4) Score clusters by total moving duration they contain
%     % (useful if you need to prune to a max number of windows later)
%     cluScore = seconds(cluE - cluS);
% 
%     % --- 5) For each cluster, pad and tile with non-overlapping 48h windows
%     candStarts = datetime.empty(0,1);
%     candEnds   = datetime.empty(0,1);
%     for c = 1:numel(cluS)
%         padS = cluS(c) - prePad;
%         padE = cluE(c) + postPad;
%         if padE <= padS, continue; end
% 
%         % compute non-overlapping 48h window starts that cover [padS, padE]
%         lastStart = padE - winDur;
%         if lastStart < padS
%             % cluster shorter than 48h (after padding): single window
%             s0 = padS;
%             candStarts(end+1,1) = s0; 
%             candEnds(end+1,1)   = s0 + winDur; 
%         else
%             % tile from padS in steps of 48h up to lastStart
%             % (colon with duration step works for datetimes)
%             starts = (padS : winDur : lastStart).';
%             candStarts = [candStarts; starts]; %#ok<AGROW>
%             candEnds   = [candEnds;   starts + winDur]; %#ok<AGROW>
%         end
%     end
% 
%     if isempty(candStarts)
%         % fallback: one 48h window centered at the median movement time
%         midt = median([s; e]);
%         s0 = midt - winDur/2;
%         candStarts = s0;
%         candEnds   = s0 + winDur;
%     end
% 
%     % --- 6) If too many windows, keep those from the strongest clusters first
%     % Build a cluster index per candidate (which cluster each window belongs to)
%     cluIdx = zeros(size(candStarts));
%     for c = 1:numel(cluS)
%         inC = (candStarts >= (cluS(c) - prePad)) & (candStarts <= (cluE(c) + postPad));
%         cluIdx(inC) = c;
%     end
%     % Safety: if any candidate didn't fall into a padded cluster, snap to nearest cluster
%     if any(cluIdx==0)
%         z = find(cluIdx==0);
%         for ii = z.'
%             [~, cmin] = min(abs(candStarts(ii) - (cluS + prePad)));
%             cluIdx(ii) = cmin;
%         end
%     end
% 
%     % Cluster scores as double seconds (so we can sort numerically)
%     cluScore = seconds(cluE - cluS);     % duration -> double
%     scorePerCand = cluScore(cluIdx);     % per-candidate score
% 
%     % ---- FIX: sort with a table (mixed types are fine)
%     Tsort = table(scorePerCand, candStarts, (1:numel(candStarts)).', ...
%         'VariableNames', {'Score','Start','Idx'});
%     Tsort = sortrows(Tsort, {'Score','Start'}, {'descend','ascend'});
%     ord   = Tsort.Idx;
% 
%     % Apply order
%     candStarts = candStarts(ord);
%     candEnds   = candEnds(ord);
%     cluIdx     = cluIdx(ord);
% 
%     % Greedily take non-overlapping windows up to maxWindowsPerFolder
%     selS = datetime.empty(0,1); selE = datetime.empty(0,1);
%     for i = 1:numel(candStarts)
%         s0 = candStarts(i); e0 = candEnds(i);
%         overlap = false;
%         for j = 1:numel(selS)
%             if ~(e0 <= selS(j) || s0 >= selE(j))
%                 overlap = true; break;
%             end
%         end
%         if ~overlap
%             selS(end+1,1) = s0; 
%             selE(end+1,1) = e0; 
%             if numel(selS) >= maxWindowsPerFolder, break; end
%         end
%     end
% 
%     % Append to plan
%     allFolders  = [allFolders;  repmat(folder, numel(selS), 1)];
%     allStarts   = [allStarts;   selS];
%     allEnds     = [allEnds;     selE];
%     allRootDirs = [allRootDirs; repmat(folder, numel(selS), 1)];
% end
% 
% % --- 7) Build final RunPlan & (optionally) execute
% RunPlan = table(allFolders, allStarts, allEnds, allRootDirs, ...
%     'VariableNames', {'Folder','tStart','tEnd','rootDir'});
% RunPlan = sortrows(RunPlan, {'Folder','tStart'});
% 
% 
% 
% %%
% % Inputs:
% %   Nodo_perFolder : 1xF or Fx1 cell array, each cell = Nodo struct array for a folder
% %   RunPlan.Folder : (optional) string array of folder names, same length as Nodo_perFolder
% % Run:
% Nodo_sets = arrayfun(@(i) loadNodoData(RunPlan.tStart(i), RunPlan.tEnd(i), RunPlan.rootDir(i)), ...
%                       (1:height(RunPlan))', 'UniformOutput', false);
% 
% F = numel(Nodo_sets);
% 
% % Preallocate outputs
% Nodo_out_cells = cell(F,1);
% rolesTables    = cell(F,1);
% steadyInfos    = cell(F,1);
% 
% % Optional: names per folder (if you have RunPlan.Folder use that)
% if exist('RunPlan','var') && isfield(RunPlan,'Folder') && numel(RunPlan.Folder)==F
%     folderNames = string(RunPlan.Folder);
% else
%     folderNames = "Folder" + (1:F).';
% end
% 
% fprintf('\n=== Running identify_brake_sensors on %d folders ===\n', F);
% 
% for f = 1:F
%     fprintf('\n--- [%d/%d] %s ---\n', f, F, folderNames(f));
%     Nodo = Nodo_sets{f};
% 
%     [Nodo_out, rolesTable, steadyInfo] = identify_brake_sensors( ...
%         Nodo, 'FsGrid',5, 'Fc',1, 'GradTol',0.01, 'MaxGapSec',3, 'MaxWindowMin',10);
% 
%     Nodo_out_cells{f} = Nodo_out;
% 
%     % --- FIX: add a full-length Folder column ---
%     nrows = height(rolesTable);
%     folderCol = repmat(folderNames(f), nrows, 1);   % string column
%     rolesTables{f} = addvars(rolesTable, folderCol, 'Before',1, 'NewVariableNames','Folder');
% 
%     steadyInfos{f} = steadyInfo;
% end
% 
% % optional combined summary
% % rolesAll = vertcat(rolesTables{:});
% % disp(rolesAll);
% 
% %% ==== Save labeled Nodo per folder ====
% outDir = fullfile('.','DataExtraction');
% if ~exist(outDir, 'dir'), mkdir(outDir); end
% 
% F = numel(Nodo_out_cells);
% 
% for f = 1:F
%     Nodo_out = Nodo_out_cells{f};
%     folderName = string(RunPlan.Folder(f));
% 
%     if isempty(Nodo_out)
%         fprintf('[save] %s: empty Nodo_out, skipping.\n', folderName);
%         continue;
%     end
% 
%     hasLabel = arrayfun(@(s) isfield(s,'Label') && ~isempty(s.Label) && ~(isstring(s.Label) && s.Label==""), Nodo_out);
%     Nodo_filtered = Nodo_out(hasLabel);
% 
%     if isempty(Nodo_filtered)
%         fprintf('[save] %s: no labeled sensors, skipping.\n', folderName);
%         continue;
%     end
% 
%     % --- FIX: build correct date strings ---
%     tStartDate = dateshift(RunPlan.tStart(f), 'start', 'day');
%     tEndDate   = dateshift(RunPlan.tEnd(f),   'start', 'day');
%     tStartStr  = char(string(tStartDate, 'yyyyMMdd'));  % e.g., 20250616
%     tEndStr    = char(string(tEndDate,   'yyyyMMdd'));  % e.g., 20250618
% 
%     fileName = sprintf('Nodo_%s_%s_%s.mat', folderName, tStartStr, tEndStr);
%     filePath = fullfile(outDir, fileName);
% 
%     try
%         save(filePath, 'Nodo_filtered', 'folderName', 'tStartDate', 'tEndDate', '-v7.3');
%         fprintf('[save] Wrote %s (%d sensors)\n', filePath, numel(Nodo_filtered));
%     catch ME
%         warning('[save] Failed to write %s: %s', filePath, ME.message);
%     end
% end


% %% PLOT 1–7 : one subplot per node in each figure
% % Access example:
% Nodo_Dati05 = Nodo_perFolder{RunPlan.Folder == "Dati05"};
% Nodo = Nodo_Dati05;
% 
% nNode = numel(Nodo);
% hAx  = gobjects(nNode,nNode);
% %Nodo = Test;
% for t = 1:nNode
%     id     = Nodo(t).ID;
%     P      = Nodo(t).Pressure;
%     Trow   = Nodo(t).Time;          % full 80-Hz time vector
%     S      = Nodo(t).Start_time;    
% 
%     figure(1)
%     hAx(t,1) = subplot(nNode,1,t);
%     plot(Trow, P)
%     title(sprintf('Nodo %s  –  Pressure', id))
%     xlabel('Time');  ylabel('Pressure [bar]');  grid on
% 
%     figure(2)
%     hAx(t,2) = subplot(nNode,1,t);
%     plot(S, Nodo(t).Vbatt)
%     title(sprintf('Nodo %s  –  Vbatt', id))
%     xlabel('Time');  ylabel('Vbatt [V]');       grid on
% 
%     figure(3)
%     hAx(t,3) = subplot(nNode,1,t);
%     plot(S, Nodo(t).Vin)
%     title(sprintf('Nodo %s  –  Vin', id))
%     xlabel('Time');  ylabel('Vin [V]');         grid on
% 
%     figure(4)
%     hAx(t,4) = subplot(nNode,1,t);
%     plot(S, Nodo(t).Id)
%     title(sprintf('Nodo %s  –  Id', id))
%     xlabel('Time');  ylabel('Id [mA]');         grid on
% 
%     figure(5)
%     hAx(t,5) = subplot(nNode,1,t);
%     plot(S, Nodo(t).Ic)
%     title(sprintf('Nodo %s  –  Ic', id))
%     xlabel('Time');  ylabel('Ic [mA]');         grid on
% 
%     figure(6)
%     hAx(t,6) = subplot(nNode,1,t);
%     plot(S, Nodo(t).RSSI)
%     title(sprintf('Nodo %s  –  RSSI', id))
%     xlabel('Time');  ylabel('RSSI [dB]');       grid on
% 
%     figure(7)
%     hAx(t,7) = subplot(nNode,1,t);
%     plot(S, Nodo(t).Temperature)
%     title(sprintf('Nodo %s  –  Temperature', id))
%     xlabel('Time');  ylabel('T [°C]');          grid on
% end
% 
% % link x-axes figure-wise
% for f = 1:7
%     figure(f)
%     linkaxes(hAx(:,f),'x');                % all subplots in that figure
%     set(gcf,'Color','w');
% end
% figure(8);  clf
% hold on;  grid on;  set(gcf,'Color','w')
% cmap = lines(max(nNode,7));
% for k = 1:nNode
%     plot(Nodo(k).Time, Nodo(k).Pressure, ...
%          'Color', cmap(k,:), ...
%          'DisplayName', sprintf('Nodo %s', Nodo(k).ID));
% end
% title('Pressure – all sensor nodes')
% xlabel('Time');  ylabel('Pressure [bar]')
% ylim([0 7])
% legend('show','Location','bestoutside')    % builds legend from DisplayName

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