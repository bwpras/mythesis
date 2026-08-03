function Nodo = loadNodoData(tStart, tEnd, fsamp, rootDir)
%LOADNODODATA Build Nodo struct from raw BIN files within a time window.
% - Timezone-free datetimes (tz-naive)
% - +2 hours offset applied to Start_time and Time
% - Ignore MSG_WAKE telemetry in per-packet arrays (keeps Start_time aligned)
% - Reconcile telemetry lengths to Start_time (defensive)
% - Pressure calibrated at assembly:
%     pCal = ((double(rawPress) * 3.6 / 3.3) * 0.000788) - 2.3057

arguments
    tStart (1,1) datetime
    tEnd   (1,1) datetime
    fsamp  (1,1) double
    rootDir (1,1) string
end

if tEnd < tStart
    error('loadNodoData:InvalidWindow', 'End time must be >= start time.');
end
if ~isfolder(rootDir)
    error('loadNodoData:MissingFolder', 'Folder "%s" does not exist.', rootDir);
end

FCAMP    = fsamp;              % HP=40 Hz, LP≈1.62181 Hz
MSG_WAKE = hex2dec('20');

% --------- 1) RECURSIVE LIST OF CANDIDATES ---------
S = dir(fullfile(rootDir, '**', '*.bin'));
if isempty(S), Nodo = struct.empty; return; end

names   = string({S.name}).';
folders = string({S.folder}).';
paths   = fullfile(folders, names);

% --------- 2) ROBUST FILENAME PARSING ---------
expr = "^(?<YYYY>\d{4})_(?<MMDD>\d{4})(?<HH>\d{2})(?<MN>\d{2})(?<SS>\d{2}).*?_(?<kind>pjm|p)\.bin$";
tok = regexp(names, expr, 'names');

isMatch = ~cellfun('isempty', tok);
tok     = tok(isMatch);
paths   = paths(isMatch);
names   = names(isMatch);

if isempty(paths), Nodo = struct.empty; return; end

YYYY = string(cellfun(@(t) t.YYYY, tok, 'UniformOutput', false));
MMDD = string(cellfun(@(t) t.MMDD, tok, 'UniformOutput', false));
HH   = string(cellfun(@(t) t.HH,   tok, 'UniformOutput', false));
MN   = string(cellfun(@(t) t.MN,   tok, 'UniformOutput', false));
SS   = string(cellfun(@(t) t.SS,   tok, 'UniformOutput', false));
kind = string(cellfun(@(t) t.kind, tok, 'UniformOutput', false));

dtstr = YYYY + extractBetween(MMDD,1,2) + extractBetween(MMDD,3,4) + HH + MN + SS;
dt    = datetime(dtstr, 'InputFormat','yyyyMMddHHmmss');  % tz-naive

idTok = regexp(names, "_(0x[0-9a-fA-F]+)_", 'tokens', 'once');
kitID = strings(numel(names),1);
for i = 1:numel(names)
    if ~isempty(idTok{i})
        kitID(i) = string(idTok{i}{1});
    else
        kitID(i) = "";
    end
end

T = table(paths, names, dt, kind, kitID, 'VariableNames', ...
          {'Path','Name','EndTime','Kind','KitID'});

% --------- 3) FILTER BY TRUE TIME WINDOW ---------
inWindow = (T.EndTime >= tStart) & (T.EndTime <= tEnd);
Tsel = sortrows(T(inWindow, :), 'EndTime');
if isempty(Tsel), Nodo = struct.empty; return; end

hrs = hour(Tsel.EndTime);
Tsel = Tsel((hrs >= 1) & (hrs <= 23), :);
if isempty(Tsel), Nodo = struct.empty; return; end

% --------- 4) SPLIT BY MODALITY ---------
Tsel_p   = Tsel(Tsel.Kind == "p", :);
Tsel_pjm = Tsel(Tsel.Kind == "pjm", :);

% Step 1. Prepare containers (per-packet)
nodo_Press       = containers.Map;   % raw int16 pressure (flattened later)
nodo_Time        = containers.Map;   % datetime Nx80 matrices (flattened later)
nodo_Vbatt       = containers.Map;
nodo_Vin         = containers.Map;
nodo_Id          = containers.Map;
nodo_Ic          = containers.Map;
nodo_Temp        = containers.Map;
nodo_RSSI        = containers.Map;
nodo_Start_time  = containers.Map;
nodo_MSG_WAKE    = containers.Map;   % just a counter
nodo_cont_pkt    = containers.Map;
nodo_end_time    = containers.Map;

% --------- Parse pressure files ---------
for h = 1:height(Tsel_p)
    fname    = Tsel_p.Path(h);
    end_time = Tsel_p.EndTime(h);
    kit_id   = Tsel_p.KitID(h);

    if mod(h-1, 100) == 0
        fprintf('Reading pressure [%d/%d] %s\n', h, height(Tsel_p), fname);
    end

    fpi = fopen(fname, 'r');
    if fpi < 0
        warning('loadNodoData:FileOpenFailed', 'Unable to open file %s', fname);
        continue;
    end
    cleanupObj = onCleanup(@() fclose(fpi)); 

    cont_MSG_WAKE = 0;
    cont_pkt      = 0;

    if strlength(kit_id) > 0
        key = kit_id;
    else
        [~, base, ~] = fileparts(Tsel_p.Name(h));
        key = string(base);
    end

    Start_time = NaT(0,1);
    Time       = NaT(0,80);

    while ~feof(fpi)
        fread(fpi,1,'uint8');   % sohcar   (unused)
        fread(fpi,1,'uint8');   % contatore(unused)
        pktlen   = fread(fpi,1,'uint8');
        fread(fpi,1,'uint8');   % idDest   (unused)
        fread(fpi,1,'uint8');   % idSource (unused)
        PkType   = fread(fpi,1,'uint8');

        if isempty(pktlen), break; end

        % --------- MSG_WAKE: DO NOT append to per-packet telemetry ---------
        if PkType == MSG_WAKE
            cont_MSG_WAKE = cont_MSG_WAKE + 1;
            fread(fpi,1,'uint8');    % Soglia
            fread(fpi,1,'uint16');   % Vbatt
            fread(fpi,1,'uint16');   % Vin
            fread(fpi,1,'uint16');   % Id
            fread(fpi,1,'uint16');   % Ic
            fread(fpi,1,'int16');    % Temp
            fread(fpi,1,'uint8');    % RSSI
            fread(fpi,1,'uint8');    % eochar
            continue;
        end

        % --------- DATA PACKET (has Start_time and 80 samples) ---------
        % NOTE: do NOT increment cont_pkt until a full valid packet is read
        Vbatt = fread(fpi,1,'uint16');       if isempty(Vbatt), break; end
        Vbatt = Vbatt/1000;
        Vin   = fread(fpi,1,'uint16');       if isempty(Vin),   break; end
        Vin   = Vin/1000;
        Id    = fread(fpi,1,'uint16');       if isempty(Id),    break; end
        Id    = Id*0.1;
        Ic    = fread(fpi,1,'uint16');       if isempty(Ic),    break; end
        Ic    = Ic*0.1;
        Temp  = fread(fpi,1,'int16');        if isempty(Temp),  break; end
        Temp  = Temp*0.01;

        Press = zeros(80,1,'int16'); % keep raw; convert later

        Timestamp = fread(fpi,1,'uint64');
        if isempty(Timestamp)
            % Incomplete packet at EOF or corrupted stream: stop cleanly
            warning('loadNodoData:TruncatedPacket','Truncated packet (missing timestamp).');
            break;
        end

        if FCAMP == 40
            % Build time row, ensure we really have 80 samples
            st = datetime(double(Timestamp)/1000,'ConvertFrom','posixtime');
            [press80, nread] = fread(fpi,80,'int16');
            if nread < 80
                warning('loadNodoData:ShortRead','Expected 80 samples, got %d. Dropping partial packet.', nread);
                break;  % or continue;  choose break to stop at EOF
            end

            % Only now that we have a complete packet, increment the counter
            cont_pkt = cont_pkt + 1;

            Start_time(cont_pkt,1) = st;
            Time(cont_pkt,1:80)    = st + seconds((0:79)/FCAMP);
            Press(:)               = press80;

        else
            FCAMP_LP = 1.62181;
            st = datetime(double(Timestamp)/1000,'ConvertFrom','posixtime');
            [press10, nread] = fread(fpi,10,'int16');
            if nread < 10
                warning('loadNodoData:ShortReadLP','Expected 10 LP samples, got %d. Dropping partial packet.', nread);
                break;
            end

            cont_pkt = cont_pkt + 1;

            Start_time(cont_pkt,1) = st;
            Time(cont_pkt,1:10)    = st + seconds((0:9)/FCAMP_LP);
            Press(1:10)            = press10;
            fread(fpi,70,'int16'); % skip remaining to keep alignment
        end

        fread(fpi,1,'uint16');   % n_sample
        fread(fpi,1,'uint16');   % dummy1
        fread(fpi,1,'uint16');   % dummy2
        RSSI = fread(fpi,1,'uint8');
        if isempty(RSSI)
            warning('loadNodoData:TruncatedPacket','Truncated packet (missing RSSI).');
            break;
        end
        RSSI = -(256 - RSSI);
        fread(fpi,1,'uint8');    % eochar

        % ---- append to maps (unchanged) ----
        if isKey(nodo_Press, key)
            nodo_Press(key)      = [nodo_Press(key); Press(:)];
            nodo_Time(key)       = [nodo_Time(key);  Time(cont_pkt,:)];
            nodo_Vbatt(key)      = [nodo_Vbatt(key), Vbatt];
            nodo_Vin(key)        = [nodo_Vin(key),   Vin];
            nodo_Id(key)         = [nodo_Id(key),    Id];
            nodo_Ic(key)         = [nodo_Ic(key),    Ic];
            nodo_Temp(key)       = [nodo_Temp(key),  Temp];
            nodo_RSSI(key)       = [nodo_RSSI(key),  RSSI];
            nodo_Start_time(key) = [nodo_Start_time(key); Start_time(cont_pkt)];
        else
            nodo_Press(key)      = Press(:);
            nodo_Time(key)       = Time(cont_pkt,:);
            nodo_Vbatt(key)      = Vbatt;
            nodo_Vin(key)        = Vin;
            nodo_Id(key)         = Id;
            nodo_Ic(key)         = Ic;
            nodo_Temp(key)       = Temp;
            nodo_RSSI(key)       = RSSI;
            nodo_Start_time(key) = Start_time(cont_pkt);
            nodo_end_time(key)   = end_time;
        end

        nodo_cont_pkt(key) = cont_pkt;
        nodo_MSG_WAKE(key) = cont_MSG_WAKE;

    end
end

% Prepare Nodo struct template
kk = keys(nodo_Press);
n_nodi = numel(kk);

Nodo = repmat(struct('ID',[],'Time_GPS',[],'Long',[],'Lat',[], ...
    'Speed',[],'Speed_RPM',[],'GPS_Ibatt',[],'GPS_Vbatt',[], ...
    'RPM_axle',[],'Time',[],'Pressure',[],'Vbatt',[],'Vin',[], ...
    'Id',[],'Ic',[],'Temperature',[],'Start_time',[],'RSSI',[], ...
    'Sensor_Type',[],'Wagon_Type',[], 'Label',[]),  n_nodi, 1);

% --------- Read GPS (pjm) files ---------
GPS_lat_cell  = cell(height(Tsel_pjm),1);
GPS_lon_cell  = cell(height(Tsel_pjm),1);
speed_cell    = cell(height(Tsel_pjm),1);
rpm_cell      = cell(height(Tsel_pjm),1);
Ibatt_cell    = cell(height(Tsel_pjm),1);
Vbatt_cell    = cell(height(Tsel_pjm),1);
time_cell     = cell(height(Tsel_pjm),1);

for k = 1:height(Tsel_pjm)
    fname = Tsel_pjm.Path(k);
    if mod(k-1,100) == 0
        fprintf('Reading GPS [%d/%d] %s\n', k, height(Tsel_pjm), fname);
    end
    try
        [lat, lon, spd, ~, rpm_k, Ibatt_k, Vbatt_k, ~, ts] = read_pjm_file39(fname);
    catch
        warning('loadNodoData:PJMReadFailed', 'Failed to parse %s', fname);
        continue;
    end
    GPS_lat_cell{k} = lat(:);
    GPS_lon_cell{k} = lon(:);
    speed_cell{k}   = spd(:);
    rpm_cell{k}     = rpm_k(:);
    Ibatt_cell{k}   = Ibatt_k(:);
    Vbatt_cell{k}   = Vbatt_k(:);
    time_cell{k}    = ts(:);   % tz-naive returned from parser
end

if ~isempty(GPS_lat_cell)
    GPS_lat  = vertcat(GPS_lat_cell{:});
    GPS_lon  = vertcat(GPS_lon_cell{:});
    speed    = vertcat(speed_cell{:});
    rpm      = vertcat(rpm_cell{:});
    Ibatt    = vertcat(Ibatt_cell{:});
    Vbatt    = vertcat(Vbatt_cell{:});
    Time_GPS = vertcat(time_cell{:});

    valid = (GPS_lat ~= 0);
    GPS_dat = struct( ...
        'GPS_lat',  GPS_lat(valid), ...
        'GPS_lon',  GPS_lon(valid), ...
        'speed',    speed(valid), ...
        'Time_GPS', Time_GPS(valid), ...
        'rpm',      rpm(valid), ...
        'Ibatt',    Ibatt(valid), ...
        'Vbatt',    Vbatt(valid));

    wheel_diam = 0.92; % m
    GPS_dat.speed_rpm = GPS_dat.rpm .* ((1/60) * 2*pi * (wheel_diam/2) * 3.6);
else
    GPS_dat = struct('GPS_lat',[],'GPS_lon',[],'speed',[],'Time_GPS',[], ...
        'rpm',[],'Ibatt',[],'Vbatt',[],'speed_rpm',[]);
end

% % --- Canonicalize nodo_Time to column vectors (flatten Nx80 -> (N*80)x1)
% for idx = 1:n_nodi
%     key = kk{idx};
%     if isKey(nodo_Time, key) && ~isempty(nodo_Time(key))
%         tmat = nodo_Time(key);                % datetime matrix (N x 80) or vector
%         if ~iscolumn(tmat)
%             tcol = reshape(tmat.', [], 1);    % row-major flatten
%             nodo_Time(key) = tcol;
%         end
%         % alignment sanity check
%         pcol = nodo_Press(key);
%         if numel(pcol) ~= numel(nodo_Time(key))
%             warning('Time/Pressure length mismatch for key %s: Time=%d, Pressure=%d', ...
%                     key, numel(nodo_Time(key)), numel(pcol));
%         end
%     end
% end

% --- Canonicalize nodo_Time to column vectors (flatten Nx80 -> (N*80)x1)
for idx = 1:n_nodi
    key = kk{idx};

    if isKey(nodo_Time, key) && ~isempty(nodo_Time(key))

        % 1) Flatten time to column if needed
        tmat = nodo_Time(key);                 % datetime matrix (N x 80) or vector
        if ~iscolumn(tmat)
            tcol = reshape(tmat.', [], 1);     % flatten
        else
            tcol = tmat;
        end

        % 2) Apply the SAME mask to time and pressure to remove LP padding
        if isKey(nodo_Press, key) && ~isempty(nodo_Press(key))
            pcol = nodo_Press(key);

            % Guard length mismatch before masking
            L = min(numel(tcol), numel(pcol));
            tcol = tcol(1:L);
            pcol = pcol(1:L);

            mask = ~isnat(tcol);               % removes the 70 NaTs per LP packet

            % ---------- DIAGNOSTIC (2 lines) ----------
            nTotal   = L;
            nKeep    = sum(mask);
            nRemoved = nTotal - nKeep;
            if nRemoved > 0
                fprintf('[NaT-mask] %s: removed %d/%d (%.2f%%) NaT-padded samples\n', ...
                        key, nRemoved, nTotal, 100*nRemoved/max(1,nTotal));
                if nKeep >= 2
                    dtMed = median(seconds(diff(tcol(mask))), 'omitnan');
                else
                    dtMed = NaN;
                end
                fprintf('[NaT-mask] %s: kept=%d, median dt=%.3f s (Fs≈%.3f Hz)\n', ...
                        key, nKeep, dtMed, 1/dtMed);
            end
            % -----------------------------------------
            
            tcol = tcol(mask);
            pcol = pcol(mask);

            nodo_Time(key)  = tcol;
            nodo_Press(key) = pcol;
        else
            nodo_Time(key) = tcol;
        end

        % 3) Optional sanity check after fixing
        if isKey(nodo_Press, key)
            if numel(nodo_Press(key)) ~= numel(nodo_Time(key))
                warning('Time/Pressure length mismatch after NaT mask for key %s: Time=%d, Pressure=%d', ...
                        key, numel(nodo_Time(key)), numel(nodo_Press(key)));
            end
        end
    end
end



% --- Reconcile per-packet telemetry lengths to Start_time length ---
teleMaps = {nodo_Vbatt, nodo_Vin, nodo_Id, nodo_Ic, nodo_Temp, nodo_RSSI};
for idx = 1:n_nodi
    key = kk{idx};
    if isKey(nodo_Start_time, key)
        n_pkt = numel(nodo_Start_time(key));
        for m = 1:numel(teleMaps)
            if isKey(teleMaps{m}, key)
                v = teleMaps{m}(key);
                nv = numel(v);
                if nv > n_pkt      % trim extras
                    teleMaps{m}(key) = v(1:n_pkt);
                elseif nv < n_pkt  % pad with NaN
                    teleMaps{m}(key) = [v, nan(1, n_pkt - nv)];
                end
            end
        end
    end
end

% --------- Assemble Nodo struct (apply pCal and +2h offset) ---------
offset = hours(2);

for idx = 1:n_nodi
    key = kk{idx};

    % --- Time & pressure ---
    tcol = getOrDefault(nodo_Time, key, NaT(0,1));
    rawPress = getOrDefault(nodo_Press, key, int16([]));
    pCal = ((double(rawPress) * 3.6 / 3.3) * 0.000788) - 2.3057;

    % Apply +2h offset to Start_time and Time
    st = getOrDefault(nodo_Start_time, key, NaT(0,1));
    Nodo(idx).Start_time  = st + offset;
    Nodo(idx).Time        = tcol + offset;
    Nodo(idx).Pressure    = pCal;

    % --- Telemetry ---
    Nodo(idx).Vbatt       = getOrDefault(nodo_Vbatt, key, []);
    Nodo(idx).Vin         = getOrDefault(nodo_Vin,   key, []);
    Nodo(idx).Id          = getOrDefault(nodo_Id,    key, []);
    Nodo(idx).Ic          = getOrDefault(nodo_Ic,    key, []);
    Nodo(idx).Temperature = getOrDefault(nodo_Temp,  key, []);
    Nodo(idx).RSSI        = getOrDefault(nodo_RSSI,  key, []);
    Nodo(idx).Sensor_Type = [];
    Nodo(idx).Wagon_Type  = [];
    Nodo(idx).Label       = [];

    % --- GPS (left as-is; no +2h applied here) ---
    Nodo(idx).Time_GPS    = GPS_dat.Time_GPS;
    Nodo(idx).Long        = GPS_dat.GPS_lon;
    Nodo(idx).Lat         = GPS_dat.GPS_lat;
    Nodo(idx).Speed       = GPS_dat.speed;
    Nodo(idx).Speed_RPM   = GPS_dat.speed_rpm;
    Nodo(idx).GPS_Ibatt   = GPS_dat.Ibatt;
    Nodo(idx).GPS_Vbatt   = GPS_dat.Vbatt;
    Nodo(idx).RPM_axle    = GPS_dat.rpm;

    % ID
    Nodo(idx).ID          = key;
end

% ========= Sensor role cache: load-or-classify-and-save =========
folderKey = DefineFolderKey(rootDir);
idsNow    = string({Nodo.ID}).';

% Try to load existing labels; must be "complete" for current IDs
cachedTbl = ReadLabel(rootDir, folderKey);
haveCache = ~isempty(cachedTbl) ...
         && all(ismember(idsNow, cachedTbl.SensorID));

if haveCache
    % Apply cached labels (order-robust via map)
    Lmap = containers.Map(cachedTbl.SensorID, cachedTbl.SensorLabel);
    for ii = 1:numel(Nodo)
        lbl = "WV";
        key = string(Nodo(ii).ID);
        if isKey(Lmap, key), lbl = Lmap(key); end
        Nodo(ii).Label       = lbl;
        Nodo(ii).Sensor_Type = lbl;
    end
    % Optional: sort to match classifier convention (MBP → WV → BC)
    Nodo = Sort_byLabel(Nodo);
    % Keep only labels for the current sensors, ordered like Nodo
    [tf, loc] = ismember(idsNow, cachedTbl.SensorID);   % idsNow is Nodo IDs (3x1), cachedTbl may be bigger
    rolesTable = cachedTbl(loc(tf), {'SensorID','SensorLabel'});  % subset in Nodo order
    rolesTable.OriginalIdx = (1:numel(Nodo)).';
    rolesTable = movevars(rolesTable,'OriginalIdx','Before','SensorID');
    steadyInfo = struct('candidateFound',true,'fromCache',true);

    fprintf('Applied cached sensor labels for %s (%d sensors).\n', folderKey, numel(Nodo));
else
    % No complete cache ⇒ classify now
    [Nodo, rolesTable, steadyInfo] = identify_brake_sensors(Nodo);

    % Validate completeness and save registry only if exact match
    labelsNow = string({Nodo.Label}).';
    okLabels  = all(labelsNow~="") & all(ismember(labelsNow, ["MBP","BC","WV"]));
    okCount   = numel(labelsNow)==numel(idsNow);
    okUnique  = numel(unique(idsNow))==numel(idsNow);

    if okLabels && okCount && okUnique
        SaveFolderLabel(rootDir, folderKey, string({Nodo.ID}).', labelsNow);
    else
        warning('loadNodoData:LabelSaveSkip', ...
            'Skipping save: labels incomplete or invalid (|IDs|=%d, |labels|=%d, okLabels=%d).', ...
            numel(idsNow), numel(labelsNow), okLabels);
    end
end


fprintf('Selected %d pressure files and %d GPS files.\n', ...
    height(Tsel_p), height(Tsel_pjm));
end

% --------- Helper ---------
function val = getOrDefault(mapObj, key, defaultVal)
    if isKey(mapObj, key), val = mapObj(key); else, val = defaultVal; end
end

function folderKey = DefineFolderKey(rootDir)
% Extract a stable key like "Dati10" from rootDir; fallback to last folder name.
    [~, last] = fileparts(char(rootDir));
    m = regexp(last, '(Dati\d+)', 'once', 'match');
    if ~isempty(m), folderKey = string(m); else, folderKey = string(last); end
end

function regDir = LabelDirectory(rootDir) %#ok<INUSD>
% Where we put label registries per DatiXX.
% Canonical, project-root-relative location: data/interim/label_registry.
% Independent of rootDir (unlike the old <parent of rootDir>/label_registry
% scheme) so that labels are read from -- and written to -- the one registry
% shared across all DatiXX folders, regardless of which raw folder is scanned.
    thisFile = mfilename('fullpath');
    projectRoot = fileparts(fileparts(fileparts(thisFile)));
    regDir = fullfile(projectRoot, 'data', 'interim', 'label_registry');
end

function regPath = RegistryPath(rootDir, folderKey)
% Full path to label registry MAT file, e.g. label_registry/Dati10_labels.mat
    regDir  = LabelDirectory(rootDir);
    regPath = fullfile(regDir, sprintf('%s_labels.mat', folderKey));
end

function T = ReadLabel(rootDir, folderKey)
% Load SensorLabels table if present. Returns [] if missing/invalid.
    T = [];
    p = RegistryPath(rootDir, folderKey);
    if ~isfile(p), return; end
    S = load(p, 'SensorLabels');
    if ~isfield(S, 'SensorLabels'), return; end
    TT = S.SensorLabels;
    need = {'Folder','SensorID','SensorLabel'};
    if ~all(ismember(need, TT.Properties.VariableNames)), return; end
    % Normalize to strings and only keep known labels
    TT.Folder      = string(TT.Folder);
    TT.SensorID    = string(TT.SensorID);
    TT.SensorLabel = string(TT.SensorLabel);
    ok = ismember(TT.SensorLabel, ["MBP","BC","WV"]);
    T  = TT(ok, {'Folder','SensorID','SensorLabel'});
end

function SaveFolderLabel(rootDir, folderKey, idsNow, labelsNow)
% Save only if complete/correct: |rows|==|IDs|, labels ⊂ {MBP,BC,WV}, no duplicate IDs.
    idsNow    = string(idsNow(:));
    labelsNow = string(labelsNow(:));
    if numel(idsNow) ~= numel(labelsNow)
        warning('loadNodoData:LabelSaveMismatch', 'IDs and labels size mismatch.'); return;
    end
    if ~all(ismember(labelsNow, ["MBP","BC","WV"]))
        warning('loadNodoData:LabelSaveInvalid', 'Contains invalid labels. Not saving.'); return;
    end
    if numel(unique(idsNow)) ~= numel(idsNow)
        warning('loadNodoData:LabelSaveDuplicate', 'Duplicate SensorID(s). Not saving.'); return;
    end

    regDir  = LabelDirectory(rootDir);
    if ~exist(regDir, 'dir'), mkdir(regDir); end
    regPath = RegistryPath(rootDir, folderKey);

    SensorLabels = table( ...
        repmat(string(folderKey), numel(idsNow), 1), ...
        idsNow, labelsNow, ...
        'VariableNames', {'Folder','SensorID','SensorLabel'});

    tmp = [regPath '.tmp.mat'];
    save(tmp, 'SensorLabels');
    movefile(tmp, regPath, 'f');
    fprintf('Saved %d sensor labels to %s\n', height(SensorLabels), regPath);
end

function Nodo = Sort_byLabel(Nodo)
% Sort MBP first, then WV, then BC (Unknown at end)
    labels = string({Nodo.Label}).';
    orderCat = categorical(labels, {'MBP','WV','BC','Unknown'}, 'Ordinal', true);
    [~, ord] = sort(orderCat);
    Nodo = Nodo(ord);
end
