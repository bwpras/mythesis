clc
clear
close all


[fileTable, flatenedTable] = buildPJMFileTable();

%%
folderFilter = "Dati01";

tStart = datetime(2025,6,5);
tEnd   = datetime(2025,7,24);

subset = flatenedTable( flatenedTable.Folder == folderFilter & ...
               flatenedTable.Date   >= tStart     & ...
               flatenedTable.Date   <= tEnd, : );

%%
function [fileTable, Tall] = buildPJMFileTable()
% buildPJMFileTable
%  - Select ROOT folder containing Dati01..Dati35
%  - Load existing PJM_FileTable.mat (if present)
%  - Scan DatiXX folders for *_pjm.bin, *_p.bin, *_a.bin
%  - Build wide table (Date × DatiXX) with struct(PJM,P,A)
%  - Add DateAdded = datetime('now') for this scan
%  - Merge with existing table by Date (update or append)
%  - Flatten to long format (one row per file)
%  - Save:
%        ROOT\PJM_FileTable.mat   (fileTable, Tall)
%        ROOT\PJM_Files_Long.csv  (Tall only)

    % ---------------- SELECT ROOT FOLDER ----------------
    rootFolder = uigetdir(pwd, 'Select the ROOT folder containing Dati01..Dati35');
    if isequal(rootFolder,0)
        error('No folder selected. Operation cancelled.');
    end

    matPath = fullfile(rootFolder, 'Database_Merci.mat');
    csvPath = fullfile(rootFolder, 'Database_Merci_expand.csv');

    % ---------------- LOAD EXISTING TABLE (IF ANY) ----------------
    fileTable_old = [];
    if exist(matPath, 'file')
        S = load(matPath);
        if isfield(S, 'fileTable')
            fileTable_old = S.fileTable;
            fprintf('>> Loaded existing table from %s\n', matPath);
            fprintf('   Existing size: %d dates × %d variables\n', ...
                height(fileTable_old), width(fileTable_old));
            % If old table has no DateAdded (very first version), add it
            if ~ismember('DateAdded', fileTable_old.Properties.VariableNames)
                fileTable_old.DateAdded = NaT(height(fileTable_old),1);
            end
        end
    end

    % ---------------- FIND DatiXX FOLDERS ----------------
    d = dir(fullfile(rootFolder, 'Dati*'));
    isDir = [d.isdir];
    d = d(isDir);

    keep = ~cellfun(@isempty, regexp({d.name}, '^Dati\d{2}$', 'once'));
    d = d(keep);

    if isempty(d)
        error('No DatiXX folders found in "%s".', rootFolder);
    end

    folderNames = {d.name};
    nFolders    = numel(folderNames);

    fprintf('>> Found %d folders (DatiXX)\n', nFolders);

    % ---------------- SCAN ALL FILES (NEW TABLE) ----------------
    allDates   = datetime.empty(0,1);
    folderInfo = cell(nFolders,1);

    for fIdx = 1:nFolders

        thisFolderName = folderNames{fIdx};
        thisFolder     = fullfile(rootFolder, thisFolderName);

        fprintf('>> Scanning folder: %s\n', thisFolderName);

        filesBin = dir(fullfile(thisFolder, '*_*.bin'));
        fprintf('   Found %d files\n', numel(filesBin));

        infoStruct = struct('Date', datetime.empty(0,1), ...
                            'Type', strings(0,1), ...
                            'Name', strings(0,1));

        for k = 1:numel(filesBin)
            fname = filesBin(k).name;
            [dt, ftype] = parsePJMfilename(fname);

            if isnat(dt) || ftype == ""
                continue;
            end

            infoStruct.Date(end+1,1) = dt;
            infoStruct.Type(end+1,1) = ftype;
            infoStruct.Name(end+1,1) = string(fname);

            allDates(end+1,1) = dt; %#ok<AGROW>
        end

        folderInfo{fIdx} = infoStruct;
    end

    if isempty(allDates)
        error('No PJM/P/A .bin files found.');
    end

    uniqueDates = unique(allDates);
    nDates      = numel(uniqueDates);

    % ----- Add DateAdded column: "when this scan was run" -----
    scanTime   = datetime('now');
    DateAdded  = repmat(scanTime, nDates, 1);

    % ---------------- BUILD NEW WIDE TABLE ----------------
    fileTable_new = table(uniqueDates, DateAdded, ...
        'VariableNames', {'Date','DateAdded'});

    for fIdx = 1:nFolders
        fileTable_new.(folderNames{fIdx}) = cell(nDates,1);
    end

    for fIdx = 1:nFolders
        info = folderInfo{fIdx};

        for iDate = 1:nDates
            dt  = uniqueDates(iDate);
            mask = info.Date == dt;
            if ~any(mask), continue; end

            sub = subsetStruct(info, mask);

            entry.PJM = sub.Name(sub.Type=="pjm");
            entry.P   = sub.Name(sub.Type=="p");
            entry.A   = sub.Name(sub.Type=="a");

            fileTable_new.(folderNames{fIdx}){iDate} = entry;
        end
    end

    fprintf('>> New scan table size: %d dates × %d variables\n', ...
        height(fileTable_new), width(fileTable_new));

    % ---------------- MERGE OLD + NEW BY DATE ----------------
    if isempty(fileTable_old)
        fileTable = fileTable_new;
    else
        fileTable = mergeFileTables(fileTable_old, fileTable_new);
    end

    % Sort by Date
    [~, ord] = sort(fileTable.Date);
    fileTable = fileTable(ord,:);

    fprintf('>> Merged table size: %d dates × %d variables\n', ...
        height(fileTable), width(fileTable));

    % ---------------- FLATTEN TO LONG FORMAT ----------------
    Tall = flattenPJMTable(fileTable);

    % ---------------- SAVE TO .MAT AND .CSV ----------------
    save(matPath, 'fileTable', 'Tall');
    fprintf('>> Saved MAT file: %s\n', matPath);

    writetable(Tall, csvPath);
    fprintf('>> Saved CSV file: %s\n', csvPath);
end

function Tall = flattenPJMTable(T)
% Convert wide date × DatiXX table into a long (row-per-file) table.
% Expects T to have at least: Date, DateAdded, DatiXX...

    varNames = T.Properties.VariableNames;

    % First two are assumed: 'Date', 'DateAdded'
    folderVars = varNames(3:end);

    DateCol      = datetime.empty(0,1);
    FolderCol    = strings(0,1);
    TypeCol      = strings(0,1);
    NameCol      = strings(0,1);
    DateAddedCol = datetime.empty(0,1);

    for i = 1:height(T)
        dt        = T.Date(i);
        dateAdded = T.DateAdded(i);

        for f = 1:numel(folderVars)
            folderName = folderVars{f};
            entry = T.(folderName){i};

            if isempty(entry)
                continue;
            end

            % PJM files
            for k = 1:numel(entry.PJM)
                DateCol(end+1,1)      = dt;
                FolderCol(end+1,1)    = folderName;
                TypeCol(end+1,1)      = "PJM";
                NameCol(end+1,1)      = entry.PJM(k);
                DateAddedCol(end+1,1) = dateAdded;
            end

            % P files
            for k = 1:numel(entry.P)
                DateCol(end+1,1)      = dt;
                FolderCol(end+1,1)    = folderName;
                TypeCol(end+1,1)      = "P";
                NameCol(end+1,1)      = entry.P(k);
                DateAddedCol(end+1,1) = dateAdded;
            end

            % A files
            for k = 1:numel(entry.A)
                DateCol(end+1,1)      = dt;
                FolderCol(end+1,1)    = folderName;
                TypeCol(end+1,1)      = "A";
                NameCol(end+1,1)      = entry.A(k);
                DateAddedCol(end+1,1) = dateAdded;
            end
        end
    end

    Tall = table(DateCol, DateAddedCol, FolderCol, TypeCol, NameCol, ...
        'VariableNames', ["Date", "DateAdded", "Folder", "Type", "Filename"]);
end

function [dt, ftype] = parsePJMfilename(fname)
% Extract date (yyyyMMdd) and type (pjm|p|a) from filename.
    dt = NaT; ftype = "";
    [~, name, ~] = fileparts(fname);

    % type suffix
    tokType = regexp(name, '_(pjm|p|a)$', 'tokens', 'once');
    if isempty(tokType), return; end
    ftype = string(tokType{1});

    % date part: 2025_0725235603 → yyyy + mmdd
    tokDate = regexp(name, '^(?<year>\d{4})_(?<mmdd>\d{4})(?<time>\d{6})', 'names', 'once');
    if isempty(tokDate), return; end

    dateStr = [tokDate.year tokDate.mmdd];  % "20250725"
    dtFull  = datetime(dateStr, 'InputFormat','yyyyMMdd');
    dt      = dateshift(dtFull, 'start', 'day');
end

function out = subsetStruct(s, mask)
    fn = fieldnames(s);
    out = struct();
    for i = 1:numel(fn)
        out.(fn{i}) = s.(fn{i})(mask,:);
    end
end
