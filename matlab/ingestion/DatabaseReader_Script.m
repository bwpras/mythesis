%% Database Reader Support script to allocate the Database.mat

%% ================= PJM batch GPS plot to webmap =================
% Depends on: read_pjm_file39(fname)
% Requirements:
% 1) Folders: Dati01 ... Dati35 under a selected base directory
% 2) Filenames like: 2025_1031230000_0x00_pjm.bin
%       - 2025      -> year
%       - 1031      -> MMDD = Oct 31
%       - 230000    -> HHMMSS = 23:00:00
% 3) Plot GPS lat/lon on webmap, breaking lines at large time gaps
%
% Main optimizations:
% - Reduce number of webmap objects: 1 wmline per file by using NaN breaks
% - Avoid growing table in loops: collect rows in struct array then table once
% - Faster filename parse (sscanf) instead of regexp
% - Optional plotting/markers to prevent UI/memory overload

clear; clc; close all;

%% -------------------- USER SELECT BASE DIRECTORY -----------------
baseDir = uigetdir(pwd, 'Select base folder containing Dati01..Dati35');
if isequal(baseDir, 0)
    error('No base directory selected.');
end

% Prefer the GPSSummary.mat inside baseDir (more consistent than current folder)
matPath = fullfile(baseDir, 'GPSSummary.mat');

%% -------------------- GUI: START SCRATCH vs LOAD -----------------
choice = questdlg( ...
    sprintf('Base folder:\n%s\n\nHow do you want to proceed?', baseDir), ...
    'GPS Summary - Start Mode', ...
    'Start from scratch', 'Load existing GPSSummary.mat', 'Cancel', ...
    'Load existing GPSSummary.mat');

if isempty(choice) || strcmp(choice, 'Cancel')
    error('Operation cancelled by user.');
end

useExisting = strcmp(choice, 'Load existing GPSSummary.mat');

if useExisting
    if ~isfile(matPath)
        uiwait(warndlg(sprintf('File not found:\n%s\n\nSwitching to Start from scratch.', matPath), ...
            'GPSSummary.mat not found'));
        useExisting = false;
    else
        S = load(matPath);
        if ~isfield(S, 'GPS_Summary')
            error('GPSSummary.mat exists but does not contain variable GPS_Summary.');
        end
        GPS_Summary = S.GPS_Summary;

        % Basic sanity: ensure datetimes
        if ismember("StartTime", GPS_Summary.Properties.VariableNames) && ~isdatetime(GPS_Summary.StartTime)
            GPS_Summary.StartTime = datetime(GPS_Summary.StartTime, 'TimeZone','Europe/Rome');
        end
        if ismember("EndTime", GPS_Summary.Properties.VariableNames) && ~isdatetime(GPS_Summary.EndTime)
            GPS_Summary.EndTime = datetime(GPS_Summary.EndTime, 'TimeZone','Europe/Rome');
        end
        if ismember("Date", GPS_Summary.Properties.VariableNames) && ~isdatetime(GPS_Summary.Date)
            GPS_Summary.Date = datetime(GPS_Summary.Date, 'TimeZone','Europe/Rome');
        end

        fprintf('Loaded GPS_Summary from: %s (%d rows)\n', matPath, height(GPS_Summary));
    end
end

%% -------------------- DATE RANGE SELECTION (SCRATCH MODE ONLY) -----------------
if ~useExisting
    % Default values
    defaultStart = datetime(2025,9,1,0,0,0,'TimeZone','Europe/Rome');
    defaultEnd   = datetime(2025,12,17,0,0,0,'TimeZone','Europe/Rome');

    prompt = { ...
        'Start date (yyyy-mm-dd HH:MM:SS):', ...
        'End date   (yyyy-mm-dd HH:MM:SS):' ...
    };
    dlgtitle = 'Select PJM Scan Date Range';
    dims = [1 45];
    definput = { ...
        datestr(defaultStart,'yyyy-mm-dd HH:MM:SS'), ...
        datestr(defaultEnd,  'yyyy-mm-dd HH:MM:SS') ...
    };

    answer = inputdlg(prompt, dlgtitle, dims, definput);

    if isempty(answer)
        error('Operation cancelled during date selection.');
    end

    % Parse user input
    try
        dateStart = datetime(answer{1}, ...
            'InputFormat','yyyy-MM-dd HH:mm:ss', ...
            'TimeZone','Europe/Rome');

        dateEnd   = datetime(answer{2}, ...
            'InputFormat','yyyy-MM-dd HH:mm:ss', ...
            'TimeZone','Europe/Rome');
    catch
        error('Invalid date format. Use yyyy-mm-dd HH:MM:SS');
    end

    % Sanity check
    if dateEnd <= dateStart
        error('End date must be later than Start date.');
    end

    fprintf('Using date range:\n  Start: %s\n  End:   %s\n', ...
        datestr(dateStart), datestr(dateEnd));
end


% dateStart = datetime(2025,9,01,0,0,0,'TimeZone','Europe/Rome');
% dateEnd   = datetime(2025,12,17,0,0,0,'TimeZone','Europe/Rome');

todStart = [];   % [] to ignore
todEnd   = [];   % [] to ignore

gapSeconds   = 1800;     % break segments where time gap > gapSeconds
lineWidth    = 2;
wheelDiam_m  = 0.92;
fileGlob     = '*_pjm.bin';

% --- Performance knobs (VERY helpful to avoid crashes)
doPlot        = false;    % set false to only build summary without webmap
doMarkers     = false;   % markers are expensive; keep false for big batches
decimateStep  = 1;       % >1 to plot fewer points (e.g., 5 means keep 1/5)
maxFilesTotal = inf;     % set e.g. 2000 to hard cap batch size

color_cmap = lines(35);

%% -------------------- PREPARE WEBMAP ----------------------------
if doPlot
    wm = webmap('OpenStreetMap');
    set(gcf, 'Color', 'w');
end

%% -------------------- BUILD A SINGLE FILE LIST -------------------
% Faster than repeatedly dir() deep inside nested loops when folders are large.
if ~useExisting
    fileList = struct('k',{},'subName',{},'folder',{},'name',{},'path',{},'fileDT',{});
    nFound = 0;
    
    fprintf('Scanning DatiXX folders under: %s\n', baseDir);
    
    for k = 1:35
        subName = sprintf('Dati%02d', k);
        subDir  = fullfile(baseDir, subName);
        if ~isfolder(subDir), continue; end
    
        L = dir(fullfile(subDir, fileGlob));
        if isempty(L), continue; end
    
        for i = 1:numel(L)
            fname = L(i).name;
    
            % Parse: YYYY_MMDDHHMMSS_0x??_pjm.bin  (example 2025_1031230000_0x00_pjm.bin)
            [ok, fileDT] = parse_pjm_filename_datetime(fname);
            if ~ok
                continue;
            end
    
            if fileDT < dateStart || fileDT > dateEnd
                continue;
            end
    
            if ~isempty(todStart) && ~isempty(todEnd)
                tod = timeofday(fileDT);
                if tod < todStart || tod > todEnd
                    continue;
                end
            end
    
            nFound = nFound + 1;
            fileList(nFound).k       = k;
            fileList(nFound).subName = subName;
            fileList(nFound).folder  = L(i).folder;
            fileList(nFound).name    = fname;
            fileList(nFound).path    = fullfile(L(i).folder, fname);
            fileList(nFound).fileDT  = fileDT;
    
            if nFound >= maxFilesTotal
                break;
            end
        end
    
        if nFound >= maxFilesTotal
            break;
        end
    end
    
    fprintf('Files selected after filters: %d\n', nFound);
    if nFound == 0
        warning('No files matched your filters. Nothing to do.');
        return;
    end
    
    %% -------------------- PREALLOCATE SUMMARY STORAGE ----------------
    % Use struct array to avoid table growth; convert to table once at end.
    GPS_rows(nFound,1) = struct( ...
        'FolderName',"", ...
        'FileName',"", ...
        'Date',datetime(NaN,NaN,NaN,'TimeZone','Europe/Rome'), ...
        'StartTime',datetime(NaN,NaN,NaN,'TimeZone','Europe/Rome'), ...
        'EndTime',datetime(NaN,NaN,NaN,'TimeZone','Europe/Rome'), ...
        'GPS_Lat',NaN, ...
        'GPS_Lon',NaN, ...
        'GPS_Speed',NaN, ...
        'GPS_Speed_RPM',NaN, ...
        'GPS_RPM',NaN);

    rowCount = 0;
    
    %% -------------------- PROCESS FILES ------------------------------
    for idxFile = 1:nFound
        k       = fileList(idxFile).k;
        subName = fileList(idxFile).subName;
        fpath   = fileList(idxFile).path;
        fname   = fileList(idxFile).name;
        fileDT  = fileList(idxFile).fileDT;
    
        fprintf('(%d/%d) Reading: %s\n', idxFile, nFound, fpath);
    
        try
            [lat, lon, spd, ~, rpm_k, ~, ~, ~, ts] = read_pjm_file39(fpath);
        catch ME
            warning('read_pjm_file39 failed on %s\n  -> %s', fpath, ME.message);
            continue;
        end
    
        % Ensure column vectors
        lat = lat(:); lon = lon(:); spd = spd(:); rpm_k = rpm_k(:); ts = ts(:);
    
        % Guard: lengths must match
        N = min([numel(lat), numel(lon), numel(spd), numel(rpm_k), numel(ts)]);
        if N < 2
            continue;
        end
        lat = lat(1:N); lon = lon(1:N); spd = spd(1:N); rpm_k = rpm_k(1:N); ts = ts(1:N);
    
        % ---------------- FILTER VALID POINTS ----------------
        % Use AND (both lat & lon must be valid).
        % Add rpm ~= 308 filter if 308 is your known invalid code.
        validGPS = (lat > 0.001) & (lon > 0.001) & isfinite(lat) & isfinite(lon);
        validRPM = (rpm_k ~= 308) & isfinite(rpm_k);
        validTS  = ~isnat(ts);
    
        valid = validGPS & validRPM & validTS;
    
        lat_c = lat(valid);
        lon_c = lon(valid);
        spd_c = spd(valid);
        rpm_c = rpm_k(valid);
        ts_c  = ts(valid);
    
        if numel(ts_c) < 2
            fprintf('  Skipped (not enough valid points).\n');
            continue;
        end
    
        % Optional decimation (dramatically reduces webmap load)
        if decimateStep > 1
            keep = 1:decimateStep:numel(ts_c);
            lat_c = lat_c(keep);
            lon_c = lon_c(keep);
            spd_c = spd_c(keep);
            rpm_c = rpm_c(keep);
            ts_c  = ts_c(keep);
            if numel(ts_c) < 2
                continue;
            end
        end
    
        % RPM -> speed (km/h)
        R = wheelDiam_m/2;
        speed_rpm = rpm_c .* ((1/60) * 2*pi * R * 3.6);
    
        % ---------------- BREAK INTO SEGMENTS (NaN separators) ----------------
        % Instead of calling wmline per segment, we create a single polyline:
        % Insert NaNs where gaps occur, then call wmline ONCE.
        dt = seconds(diff(ts_c));
        gapIx = find(dt > gapSeconds);
    
        lat_plot = lat_c;
        lon_plot = lon_c;
    
        if ~isempty(gapIx)
            % Insert NaN after each gap index (work backwards to keep indices valid)
            for g = numel(gapIx):-1:1
                ii = gapIx(g);
                lat_plot = [lat_plot(1:ii); NaN; lat_plot(ii+1:end)];
                lon_plot = [lon_plot(1:ii); NaN; lon_plot(ii+1:end)];
            end
        end
    
        % ---------------- PLOT (OPTIONAL) ----------------
        if doPlot
            col = color_cmap(k, :);
    
            try
                wmline(lat_plot, lon_plot, ...
                    'Color', col, ...
                    'Width', lineWidth, ...
                    'FeatureName', sprintf('%s | %s', subName, datestr(fileDT,'yyyy-mm-dd HH:MM:ss')));
            catch MEp
                warning('wmline failed for %s -> %s', fpath, MEp.message);
            end
    
            if doMarkers
                % Mark start/end points (avoid in large batches)
                try
                    wmmarker(lat_c(1),  lon_c(1),  'FeatureName', sprintf('%s START %s', subName, datestr(ts_c(1))));
                    wmmarker(lat_c(end), lon_c(end), 'FeatureName', sprintf('%s END   %s', subName, datestr(ts_c(end))));
                catch
                    % ignore marker failures
                end
            end
        end
    
        % ---------------- SUMMARY ROW (FAST) ----------------
        rowCount = rowCount + 1;
        GPS_rows(rowCount).FolderName    = string(subName);
        GPS_rows(rowCount).FileName      = string(fname);
        GPS_rows(rowCount).Date          = datetime(year(fileDT), month(fileDT), day(fileDT), 'TimeZone','Europe/Rome');
        GPS_rows(rowCount).StartTime     = ts_c(1);
        GPS_rows(rowCount).EndTime       = ts_c(end);
        GPS_rows(rowCount).GPS_Lat       = mean(lat_c, 'omitnan');
        GPS_rows(rowCount).GPS_Lon       = mean(lon_c, 'omitnan');
        GPS_rows(rowCount).GPS_Speed     = mean(spd_c, 'omitnan');
        GPS_rows(rowCount).GPS_Speed_RPM = mean(speed_rpm, 'omitnan');
        GPS_rows(rowCount).GPS_RPM       = mean(rpm_c, 'omitnan');

    
        % Console summary (cheap)
        nSeg = 1 + numel(gapIx);
        fprintf('  Points: %5d | Segments: %d | Speed[km/h] GPS(mean)=%.1f RPM(mean)=%.1f\n', ...
            numel(ts_c), nSeg, GPS_rows(rowCount).GPS_Speed, GPS_rows(rowCount).GPS_Speed_RPM);
    end
    
    %% -------------------- FINALIZE SUMMARY TABLE ---------------------
    if rowCount == 0
        warning('No valid data collected for GPS_Summary.');
        disp('Done.');
        return;
    end
    
    GPS_rows = GPS_rows(1:rowCount);
    GPS_Summary = struct2table(GPS_rows);
end
%% ===================== PRESSURE AVAILABILITY (PressureOK) =====================
% For each GPS_Summary row, check if there exists at least one *_p.bin
% within the same FolderName and within [StartTime, EndTime].

fprintf('\nBuilding pressure file index (*_p.bin) per folder...\n');

% Build an index: FolderName -> sorted vector of pressure file datetimes
pIndex = containers.Map('KeyType','char','ValueType','any');

for k = 1:35
    subName = sprintf('Dati%02d', k);
    subDir  = fullfile(baseDir, subName);
    if ~isfolder(subDir)
        continue;
    end

    Lp = dir(fullfile(subDir, '*_p.bin'));
    if isempty(Lp)
        pIndex(subName) = datetime.empty(0,1);
        continue;
    end

    pDT = datetime(NaN(numel(Lp),1), NaN(numel(Lp),1), NaN(numel(Lp),1), ...
        NaN(numel(Lp),1), NaN(numel(Lp),1), NaN(numel(Lp),1), ...
        'TimeZone','Europe/Rome');
    keep = false(numel(Lp),1);

    for i = 1:numel(Lp)
        [okp, dtp] = parse_p_filename_datetime(Lp(i).name);
        if okp
            pDT(i) = dtp;
            keep(i) = true;
        end
    end

    pDT = pDT(keep);
    pDT = sort(pDT(:));  % sort once for fast lookup
    pIndex(subName) = pDT;

    fprintf('  %-6s : %5d pressure files indexed\n', subName, numel(pDT));
end

% Preallocate output column
PressureOK = zeros(height(GPS_Summary),1,'uint8');

% Ensure Start/End are datetimes (they should already be)
if ~isdatetime(GPS_Summary.StartTime), GPS_Summary.StartTime = datetime(GPS_Summary.StartTime); end
if ~isdatetime(GPS_Summary.EndTime),   GPS_Summary.EndTime   = datetime(GPS_Summary.EndTime);   end

fprintf('\nComputing PressureOK for %d GPS rows...\n', height(GPS_Summary));
%% ---- Normalize datetime time zones (MUST be consistent) ----
tz = 'Europe/Rome';

% Ensure StartTime/EndTime are datetime
if ~isdatetime(GPS_Summary.StartTime)
    GPS_Summary.StartTime = datetime(GPS_Summary.StartTime);
end
if ~isdatetime(GPS_Summary.EndTime)
    GPS_Summary.EndTime = datetime(GPS_Summary.EndTime);
end

% Force timezone onto StartTime/EndTime if missing
if isempty(GPS_Summary.StartTime.TimeZone)
    GPS_Summary.StartTime.TimeZone = tz;
end
if isempty(GPS_Summary.EndTime.TimeZone)
    GPS_Summary.EndTime.TimeZone = tz;
end

% (Optional) Date column too
if ismember("Date", GPS_Summary.Properties.VariableNames) && isdatetime(GPS_Summary.Date) ...
        && isempty(GPS_Summary.Date.TimeZone)
    GPS_Summary.Date.TimeZone = tz;
end


for r = 1:height(GPS_Summary)
    % --- get folder as string scalar (robust) ---
    folderName = string(GPS_Summary.FolderName(r));
    t0 = GPS_Summary.StartTime(r);
    t1 = GPS_Summary.EndTime(r);

    % --- guards must be logical scalars ---
    if strlength(strtrim(folderName)) == 0 || ismissing(folderName) || isnat(t0) || isnat(t1)
        PressureOK(r) = 0;
        continue;
    end

    key = char(folderName);   % containers.Map needs char key


    if ~isKey(pIndex, key)
        PressureOK(r) = 0;
        continue;
    end

    pDT = pIndex(key);
    if isempty(pDT)
        PressureOK(r) = 0;
        continue;
    end

    % Fast interval hit test using sorted timestamps:
    % find first pDT >= t0, then check if it's <= t1
    j = find(pDT >= t0, 1, 'first');
    if ~isempty(j) && pDT(j) <= t1
        PressureOK(r) = 1;
    else
        PressureOK(r) = 0;
    end
end


% Append column
GPS_Summary.PressureOK = PressureOK;

% Quick stats
rate = 100 * mean(double(PressureOK));
fprintf('PressureOK: %d/%d (%.1f%%)\n', sum(PressureOK), numel(PressureOK), rate);

%% Save
outFile = fullfile(baseDir, 'GPS_Summary_All.xlsx');
writetable(GPS_Summary, outFile);

save(fullfile(baseDir,'GPSSummary.mat'),'GPS_Summary');   % <- recommended: save inside baseDir
disp('Done')

%%


% % load("GPSSummary.mat")
% % 
% % %% === Filter GPS_Summary by distance to Marcianise ===
% % % Assumes you already have a table GPS_Summary with columns:
% % % GPS_Lat (double), GPS_Lon (double), Date, StartTime, EndTime, etc.
% % 
% % % Target (Marcianise)
% % lat0 = 41.0371;    % deg
% % lon0 = 14.2995;    % deg
% % 
% % % Radius threshold (km)
% % radius_km = 15;    % e.g., show rows within 15 km
% % 
% % % Haversine distance (vectorized)
% % R = 6371.0; % Earth radius in km
% % lat  = GPS_Summary.GPS_Lat(:);
% % lon  = GPS_Summary.GPS_Lon(:);
% % 
% % % Use built-in deg2rad if available; otherwise fallback
% % if exist('deg2rad','file')
% %     lat  = deg2rad(lat);
% %     lon  = deg2rad(lon);
% %     lat0r = deg2rad(lat0);
% %     lon0r = deg2rad(lon0);
% % else
% %     lat0r = lat0*pi/180; lon0r = lon0*pi/180;
% %     lat   = lat*pi/180;  lon   = lon*pi/180;
% % end
% % 
% % dlat = lat - lat0r;
% % dlon = lon - lon0r;
% % a = sin(dlat/2).^2 + cos(lat0r).*cos(lat).*sin(dlon/2).^2;
% % c = 2*atan2(sqrt(a), sqrt(1-a));
% % dist_km = R * c;
% % 
% % % Append distance and filter
% % GPS_Summary.Distance_km = dist_km;
% % ix = dist_km <= radius_km;
% % GPS_Summary_Marcianise = GPS_Summary(ix, :);
% % 
% % % Optional: sort by distance, then by StartTime
% % if ismember("StartTime", GPS_Summary_Marcianise.Properties.VariableNames)
% %     GPS_Summary_Marcianise = sortrows(GPS_Summary_Marcianise, {"Distance_km","StartTime"});
% % else
% %     GPS_Summary_Marcianise = sortrows(GPS_Summary_Marcianise, "Distance_km");
% % end
% % 
% % % Show a quick preview
% % disp(GPS_Summary_Marcianise(1:min(10,height(GPS_Summary_Marcianise)), :));
% % 
% % % Optional: export
% % outFile = fullfile(baseDir, sprintf('GPS_Summary_Marcianise_%dkm.xlsx', radius_km));
% % writetable(GPS_Summary_Marcianise, outFile);
% % fprintf('Saved filtered summary to: %s\n', outFile);
% 
% disp('Done.');

%% ====================== HELPER FUNCTION ==========================
function [ok, fileDT] = parse_pjm_filename_datetime(fname)
% Fast parse for: YYYY_MMDDHHMMSS_0x??_pjm.bin
% Returns ok=false if not matching.

    ok = false;
    fileDT = NaT;

    % Quick length sanity (avoids doing work on obviously wrong names)
    if length(fname) < 24
        return;
    end

    % Parse using sscanf (much cheaper than regexp in large loops)
    % Expect: YYYY_MMDDHHMMSS_0x??_pjm.bin
    % We'll scan the leading numeric blocks first.
    tmp = sscanf(fname, '%4d_%4d%6d_0x%2x_pjm.bin');
    if numel(tmp) ~= 4
        return;
    end

    yyyy  = tmp(1);
    mmdd  = tmp(2);
    hhmmss= tmp(3);
    % hex   = tmp(4);  %#ok<NASGU>  % not used

    MM = floor(mmdd/100);
    DD = mod(mmdd, 100);

    HH = floor(hhmmss/10000);
    MN = floor(mod(hhmmss,10000)/100);
    SS = mod(hhmmss, 100);

    % Basic validity checks (protect against weird filenames)
    if MM < 1 || MM > 12 || DD < 1 || DD > 31 || HH > 23 || MN > 59 || SS > 59
        return;
    end

    fileDT = datetime(yyyy, MM, DD, HH, MN, SS, 'TimeZone','Europe/Rome');
    ok = ~isnat(fileDT);
end

function [ok, fileDT] = parse_p_filename_datetime(fname)
% Fast parse for: YYYY_MMDDHHMMSS_0x??_p.bin
% Returns ok=false if not matching.

    ok = false;
    fileDT = NaT;

    if length(fname) < 22
        return;
    end

    tmp = sscanf(fname, '%4d_%4d%6d_0x%2x_p.bin');
    if numel(tmp) ~= 4
        return;
    end

    yyyy   = tmp(1);
    mmdd   = tmp(2);
    hhmmss = tmp(3);

    MM = floor(mmdd/100);
    DD = mod(mmdd, 100);

    HH = floor(hhmmss/10000);
    MN = floor(mod(hhmmss,10000)/100);
    SS = mod(hhmmss, 100);

    if MM < 1 || MM > 12 || DD < 1 || DD > 31 || HH > 23 || MN > 59 || SS > 59
        return;
    end

    fileDT = datetime(yyyy, MM, DD, HH, MN, SS, 'TimeZone','Europe/Rome');
    ok = ~isnat(fileDT);
end
