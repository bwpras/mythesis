%% Daily extractor for Nodo data (1-day bins, parallelized)
% - Prompts for a source directory (for example, data/raw/DatiXX)
% - Scans *.bin recursively to find actual days present
% - For each day D: tStart = D 00:00:00, tEnd = D+1 00:00:00 (next day)
% - Calls loadNodoData(tStart,tEnd,rootDir)
% - Saves under the configured data/interim directory as:
%     Nodo_DatiXX_yyyymmdd_yyyymmdd.mat
% Notes:
%   * Uses parfor to process days independently
%   * Skips output files that already exist
%   * Uses -v7.3 for large structs

clc; clear; close all;
thisFile = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(thisFile)));
addpath(fullfile(projectRoot, 'config'));
paths = matlab_paths();
fsamp = 1;

%% 1) Select source directory (rootDir) that contains the raw *.bin files
rootDir = uigetdir(paths.raw, 'Select a raw BIN folder such as data/raw/DatiXX');
if isequal(rootDir,0)
    disp('User canceled.'); return;
end
rootDir = string(rootDir);

% Try to extract "DatiXX" from the selected path for naming
tok = regexp(rootDir, 'Dati\d+', 'match', 'once');
if isempty(tok); tok = "DatiXX"; end  
datasetTag = string(tok);

%% 2) Discover all *.bin and their timestamps (yyyy_MMddHHmmss_*_(pjm|p).bin)
S = dir(fullfile(rootDir, '**', '*.bin'));
if isempty(S)
    warning('No *.bin files found under: %s', rootDir);
    return;
end
names   = string({S.name}).';
folders = string({S.folder}).';
paths   = fullfile(folders, names);

% Same robust filename parser as loadNodoData
expr = "^(?<YYYY>\d{4})_(?<MMDD>\d{4})(?<HH>\d{2})(?<MN>\d{2})(?<SS>\d{2}).*?_(?<kind>pjm|p)\.bin$";
tokn = regexp(names, expr, 'names');

isMatch = ~cellfun('isempty', tokn);
if ~any(isMatch)
    warning('No filenames matched the expected pattern under: %s', rootDir);
    return;
end
tokn   = tokn(isMatch);
paths  = paths(isMatch);
names  = names(isMatch);

YYYY = string(cellfun(@(t) t.YYYY, tokn, 'UniformOutput', false));
MMDD = string(cellfun(@(t) t.MMDD, tokn, 'UniformOutput', false));
HH   = string(cellfun(@(t) t.HH,   tokn, 'UniformOutput', false));
MN   = string(cellfun(@(t) t.MN,   tokn, 'UniformOutput', false));
SS   = string(cellfun(@(t) t.SS,   tokn, 'UniformOutput', false));
% kind = string(cellfun(@(t) t.kind, tokn, 'UniformOutput', false));  % not needed here

dtstr = YYYY + extractBetween(MMDD,1,2) + extractBetween(MMDD,3,4) + HH + MN + SS;
fileEndTime = datetime(dtstr, 'InputFormat','yyyyMMddHHmmss');  % tz-naive

%% >>> NEW BLOCK: limit to recent files only (from 1 Oct for 1 month) <<<
tMin = datetime(2026,01,01);          % start date inclusive
tMax = datetime(2026,02,18);           % one-month window: [1 Dec, 31 Dec)

inRange = (fileEndTime >= tMin) & (fileEndTime < tMax);

if ~any(inRange)
    warning('No files in the time range %s to %s.', ...
            datestr(tMin), datestr(tMax));
    return;
end

% Keep only files in the desired date range
fileEndTime = fileEndTime(inRange);
tokn        = tokn(inRange);
paths       = paths(inRange);
names       = names(inRange);
%% <<< END NEW BLOCK >>>

% Build daily bins actually present in data
dayStarts = unique(dateshift(fileEndTime, 'start', 'day'));  % midnight anchors
nDays = numel(dayStarts);
fprintf('Found %d day(s) with data in: %s\n', nDays, rootDir);


if nDays==0
    warning('No valid day boundaries could be formed.'); return;
end

%% 3) Prepare output root and per-dataset subfolder
OUT_ROOT = paths.interim;
if ~isfolder(OUT_ROOT), mkdir(OUT_ROOT); end
OUT_DIR = fullfile(OUT_ROOT, datasetTag);
if ~isfolder(OUT_DIR), mkdir(OUT_DIR); end

%% 4) Spin up a parallel pool (force process-based, v7.3-safe)
try
    % 1) Kill any existing pool (especially threads-based)
    p = gcp('nocreate');
    if ~isempty(p)
        try
            if isprop(p,'Cluster') && isprop(p.Cluster,'Type')
                fprintf('Existing pool type: %s — deleting...\n', p.Cluster.Type);
            end
        end
        delete(p);
        p = [];
    end

    % 2) Force a process pool (works across releases)
    % R2023b+ supports this:
    started = false;
    try
        parpool("Processes");   % explicitly request processes
        started = true;
    catch
        % Older MATLAB: ensure 'local' profile is active then start process pool
        try
            parallel.defaultClusterProfile('local');
        catch
            % ignore if not available
        end
        parpool('local');       % process-backed 'local' cluster
        started = true;
    end

    % 3) Verify and print
    if started
        p = gcp;  % should exist now
        poolType = '';
        try
            poolType = p.Cluster.Type;
        end
        fprintf('Parallel pool started. Cluster Type = %s, Workers = %d\n', poolType, p.NumWorkers);

        % Guard: if we still somehow got threads, stop and run serial to avoid save errors
        if strcmpi(poolType, 'threads')
            warning('Process pool was requested but a threads pool is active. Closing to avoid v7.3 save errors.');
            delete(p);
        end
    end

catch ME
    warning(ME.identifier, '%s. Continuing serially...', ME.message);
end

%% 5) Progress tracking (works in both serial and parallel contexts)
completed = 0;
total     = nDays;
t0        = tic;
if exist('parallel.pool.DataQueue','class')==8
    dq = parallel.pool.DataQueue;
    afterEach(dq, @(~) fprintf('Progress: %d/%d days (%.1f%%)\n', ...
        min(completed+1,total), total, 100*min(completed+1,total)/total));
else
    dq = [];
end

%% 6) Process each day → call loadNodoData(tStart,tEnd,rootDir) and save
% One-day span: [tStart, tEnd), naming uses yyyyMMdd_yyyyMMdd (start and next day)
parfor d = 1:nDays
    tStart = dayStarts(d);
    tEnd   = tStart + days(1);      % next midnight (inclusive in your function's filter)

    % Output filename: Nodo_DatiXX_yyyymmdd_yyyymmdd.mat
    baseName = "Nodo_" + datasetTag + "_" + string(tStart,'yyyyMMdd') + "_" + string(tEnd,'yyyyMMdd') + ".mat";
    outFile  = fullfile(OUT_DIR, baseName);

    % Skip if already exists
    if isfile(outFile)
        if ~isempty(dq), send(dq, 1); end
        continue;
    end

    try
        % Core call
        
        Nodo = loadNodoData(tStart, tEnd, fsamp, rootDir);

        % If empty, you may skip writing to avoid clutter
        if isempty(Nodo)
            % optionally, write a small marker MAT stating "empty day"
            % save(outFile, 'Nodo', '-v7.3');
            if ~isempty(dq), send(dq, 1); end
            continue;
        end

        % Save (v7.3 handles large structs safely)
        % --- inside parfor, replace the save(...) block with:
        try
            if ~isfolder(fileparts(outFile)), mkdir(fileparts(outFile)); end
            M = matfile(outFile, 'Writable', true);   % creates v7.3 .mat if new
            M.Nodo = Nodo;                             % write variable
        catch ME
            errFile = fullfile(OUT_DIR, "ERROR_" + string(tStart,'yyyyMMdd') + "_" + string(tEnd,'yyyyMMdd') + ".txt");
            fid = fopen(errFile, 'w');
            if fid > 0
                fprintf(fid, 'Error on day %s–%s\nSource: %s\nMessage: %s\n', ...
                    string(tStart,'yyyy-MM-dd'), string(tEnd,'yyyy-MM-dd'), ME.identifier, ME.message);
                if ~isempty(ME.stack)
                    for sidx = 1:numel(ME.stack)
                        fprintf(fid, '  at %s (line %d)\n', ME.stack(sidx).name, ME.stack(sidx).line);
                    end
                end
                fclose(fid);
            end
        end

    catch ME
        % Log an error file next to outputs for post-mortem
        errFile = fullfile(OUT_DIR, "ERROR_" + string(tStart,'yyyyMMdd') + "_" + string(tEnd,'yyyyMMdd') + ".txt");
        fid = fopen(errFile, 'w');
        if fid > 0
            fprintf(fid, 'Error on day %s–%s\nSource: %s\nMessage: %s\n', ...
                string(tStart,'yyyy-MM-dd'), string(tEnd,'yyyy-MM-dd'), ME.identifier, ME.message);
            if ~isempty(ME.stack)
                for sidx = 1:numel(ME.stack)
                    fprintf(fid, '  at %s (line %d)\n', ME.stack(sidx).name, ME.stack(sidx).line);
                end
            end
            fclose(fid);
        end
    end

    if ~isempty(dq), send(dq, 1); end
end

elapsedSec = toc(t0);
fprintf('Done. Processed %d day(s). Elapsed: %.1f s\n', nDays, elapsedSec);
