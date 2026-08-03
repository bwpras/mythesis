% This function reads the GPS-PJM data by loading the GPSSummary.mat files
% Run ReadPJM_batch.m first to update the database (GPSSummary.mat)
% Then this will read the table and you can select the Kit and the Day

function DatabaseReaderApp
% ---- Select base directory (contains Dati01..Dati35 and GPSSummary.mat)
baseDir = uigetdir(pwd, 'Select base folder containing Dati01..Dati35 and GPSSummary.mat');
if isequal(baseDir,0), error('No base directory selected.'); end

matPath = fullfile(baseDir, 'GPSSummary.mat');
if ~isfile(matPath), error('File not found: %s', matPath); end

S = load(matPath);
if ~isfield(S, 'GPS_Summary')
    vars = fieldnames(S);
    error('GPSSummary.mat does not contain GPS_Summary. Found: %s', strjoin(vars, ', '));
end
GPS_Summary = S.GPS_Summary;

% ===================== FILTER BY GPS SPEED =====================
% Keep only rows with GPS_Speed >= 15 km/h
if ~ismember("GPS_Speed", GPS_Summary.Properties.VariableNames)
    error('GPS_Summary does not contain GPS_Speed column.');
end

nBefore = height(GPS_Summary);

% ===================== FILTER BY SPEED (GPS OR RPM) =====================
reqSpeedCols = ["GPS_Speed", "GPS_Speed_RPM"];
missing = reqSpeedCols(~ismember(reqSpeedCols, GPS_Summary.Properties.VariableNames));
if ~isempty(missing)
    error('GPS_Summary missing required speed columns: %s', strjoin(missing, ', '));
end

nBefore = height(GPS_Summary);

gps_ok = ~isnan(GPS_Summary.GPS_Speed) & (GPS_Summary.GPS_Speed > 10);
rpm_ok = ~isnan(GPS_Summary.GPS_Speed_RPM) ...
         & (GPS_Summary.GPS_Speed_RPM > 10) ...
         & ~(GPS_Summary.GPS_RPM > 308 & GPS_Summary.GPS_RPM < 309);

% OR condition: keep if either source indicates motion
validSpeed = gps_ok | rpm_ok;

GPS_Summary = GPS_Summary(validSpeed, :);

nAfter = height(GPS_Summary);

fprintf('[INFO] GPS_Summary filtered by (GPS_Speed > 20) OR (GPS_Speed_RPM > 20): %d → %d rows (removed %d)\n', ...
    nBefore, nAfter, nBefore - nAfter);

if isempty(GPS_Summary)
    error('All rows removed after speed filtering. Check thresholds or data integrity.');
end


nAfter = height(GPS_Summary);

fprintf('[INFO] GPS_Summary filtered by GPS_Speed >= 15 km/h: %d → %d rows (removed %d)\n', ...
    nBefore, nAfter, nBefore - nAfter);

if isempty(GPS_Summary)
    error('All rows removed after GPS_Speed filtering. Check threshold.');
end


% ---- Validate table schema you provided
reqCols = ["FolderName","FileName","Date","StartTime","EndTime","GPS_Lat","GPS_Lon"];
missing = reqCols(~ismember(reqCols, GPS_Summary.Properties.VariableNames));
if ~isempty(missing)
    error('GPS_Summary missing required columns: %s', strjoin(missing, ', '));
end

% ---- Normalize types
GPS_Summary.FolderName = string(GPS_Summary.FolderName);
GPS_Summary.FileName   = string(GPS_Summary.FileName);

% ---- TimeZone consistency
tz = "Europe/Rome";
if isdatetime(GPS_Summary.StartTime)
    if ~isempty(GPS_Summary.StartTime.TimeZone)
        tz = string(GPS_Summary.StartTime.TimeZone);
    else
        GPS_Summary.StartTime.TimeZone = tz;
    end
end
if isdatetime(GPS_Summary.EndTime) && isempty(GPS_Summary.EndTime.TimeZone)
    GPS_Summary.EndTime.TimeZone = tz;
end
if isdatetime(GPS_Summary.Date) && isempty(GPS_Summary.Date.TimeZone)
    GPS_Summary.Date.TimeZone = tz;
end

% ---- Build available folders
folderList = unique(GPS_Summary.FolderName, 'stable');
if isempty(folderList), error('No folders found in GPS_Summary.'); end

%% ===================== UI FIGURE =====================
fig = uifigure('Name','PJM GPS Travel Viewer','Position',[100 100 520 260]);

uilabel(fig,'Position',[20 210 120 22],'Text','Folder');
ddFolder = uidropdown(fig, ...
    'Position',[150 210 160 22], ...
    'Items', cellstr(folderList), ...
    'Value', char(folderList(1)));

uilabel(fig,'Position',[20 175 120 22],'Text','Date');
ddDate = uidropdown(fig, ...
    'Position',[150 175 160 22], ...
    'Items', {'(loading...)'}, ...
    'Value', '(loading...)');

uilabel(fig,'Position',[20 135 120 22],'Text','gapSeconds');
spGap = uispinner(fig,'Position',[150 135 160 22], 'Limits',[1 86400], 'Value',1800);

uilabel(fig,'Position',[20 100 120 22],'Text','decimateStep');
spDec = uispinner(fig,'Position',[150 100 160 22], 'Limits',[1 200], 'Value',5);

cbMarkers = uicheckbox(fig,'Position',[150 70 200 22], 'Text','Show START/END markers', 'Value',true);

btnPlot = uibutton(fig,'push', ...
    'Position',[350 210 140 30], ...
    'Text','Plot on Webmap');

txtStatus = uitextarea(fig, ...
    'Position',[20 15 470 45], ...
    'Editable','off', ...
    'Value', {'Ready.'});

% ---- Initialize date dropdown based on initial folder
updateDateDropdown();

% ---- Callbacks
ddFolder.ValueChangedFcn = @(src,evt) updateDateDropdown();
btnPlot.ButtonPushedFcn  = @(src,evt) doPlot();

%% ===================== NESTED FUNCTIONS =====================

    function updateDateDropdown()
        fold = string(ddFolder.Value);
        mask = GPS_Summary.FolderName == fold;

        % Date might include time; normalize to day
        d = GPS_Summary.Date(mask);
        if ~isdatetime(d)
            % If Date is not datetime (unlikely), try convert:
            d = datetime(d, 'TimeZone', tz);
        end
        dDay = dateshift(d, 'start', 'day');
        uDates = unique(dDay, 'sorted');

        if isempty(uDates)
            ddDate.Items = {'(no dates)'};
            ddDate.Value = '(no dates)';
            txtStatus.Value = {sprintf('No dates available for %s', fold)};
            return;
        end

        ddDate.Items = cellstr(datestr(uDates, 'yyyy-mm-dd'));
        ddDate.Value = ddDate.Items{1};
        txtStatus.Value = {sprintf('Folder %s: %d day(s) available.', fold, numel(uDates))};
    end

    function doPlot()
        fold = string(ddFolder.Value);
        if ddDate.Value == "(no dates)" || ddDate.Value == "(loading...)"
            txtStatus.Value = {'No valid date selected.'};
            return;
        end

        % Parse selected day
        daySel = datetime(ddDate.Value, 'InputFormat','yyyy-MM-dd', 'TimeZone', tz);

        gapSeconds   = spGap.Value;
        decimateStep = spDec.Value;
        doMarkers    = cbMarkers.Value;

        % Filter table to chosen folder + chosen date (day match)
        dDayAll = dateshift(GPS_Summary.Date, 'start', 'day');
        sel = (GPS_Summary.FolderName == fold) & (dDayAll == daySel);

        T = GPS_Summary(sel,:);
        txtStatus.Value = {sprintf('Selected %d file(s) for %s on %s', height(T), fold, datestr(daySel,'yyyy-mm-dd'))};

        if isempty(T)
            warning('Selection empty.');
            return;
        end

        % Open webmap and plot
        wm = webmap('OpenStreetMap');
        set(gcf,'Color','w');
        title(sprintf('PJM GPS Trajectories | %s | %s', fold, datestr(daySel,'yyyy-mm-dd')));

        % Color per folder (single folder here, but keep structure)
        col = [0 0.4470 0.7410];

        for r = 1:height(T)
            fpath = fullfile(baseDir, char(T.FolderName(r)), char(T.FileName(r)));
            if ~isfile(fpath)
                warning('File not found: %s', fpath);
                continue;
            end

            try
                [lat, lon, ~, ~, rpm_k, ~, ~, ~, ts] = read_pjm_file39(fpath);
            catch ME
                warning('read_pjm_file39 failed: %s -> %s', fpath, ME.message);
                continue;
            end

            lat = lat(:); lon = lon(:); rpm_k = rpm_k(:); ts = ts(:);
            N = min([numel(lat), numel(lon), numel(rpm_k), numel(ts)]);
            if N < 2, continue; end
            lat = lat(1:N); lon = lon(1:N); rpm_k = rpm_k(1:N); ts = ts(1:N);

            % Ensure ts is datetime (adjust conversion to your reader if needed)
            if ~isdatetime(ts)
                ts = datetime(ts, 'ConvertFrom', 'datenum', 'TimeZone', tz);
            else
                if isempty(ts.TimeZone), ts.TimeZone = tz; end
            end

            valid = (lat > 0.001) & (lon > 0.001) & isfinite(lat) & isfinite(lon) & ~isnat(ts) & (rpm_k ~= 308);

            lat_c = lat(valid); lon_c = lon(valid); ts_c = ts(valid);
            if numel(ts_c) < 2, continue; end

            if decimateStep > 1
                keep = 1:decimateStep:numel(ts_c);
                lat_c = lat_c(keep); lon_c = lon_c(keep); ts_c = ts_c(keep);
                if numel(ts_c) < 2, continue; end
            end

            % Insert NaN separators at gaps
            dt = seconds(diff(ts_c));
            gapIx = find(dt > gapSeconds);

            lat_plot = lat_c; lon_plot = lon_c;
            for g = numel(gapIx):-1:1
                ii = gapIx(g);
                lat_plot = [lat_plot(1:ii); NaN; lat_plot(ii+1:end)];
                lon_plot = [lon_plot(1:ii); NaN; lon_plot(ii+1:end)];
            end

            % Plot one line per file
            wmline(lat_plot, lon_plot, 'Color', col, 'Width', 2, ...
                'FeatureName', sprintf('%s | %s', fold, T.FileName(r)));

            % Markers: START/END with time + folder
            if doMarkers
                tStartStr = datestr(ts_c(1), 'yyyy-mm-dd HH:MM:ss');
                tEndStr   = datestr(ts_c(end), 'yyyy-mm-dd HH:MM:ss');

                wmmarker(lat_c(1), lon_c(1), ...
                    'FeatureName', sprintf('%s | START | %s', fold, tStartStr));

                wmmarker(lat_c(end), lon_c(end), ...
                    'FeatureName', sprintf('%s | END | %s', fold, tEndStr));
            end
        end

        txtStatus.Value = {sprintf('Plotted %d file(s).', height(T))};
    end
end