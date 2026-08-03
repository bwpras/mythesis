function [TestBrake_Sets, PairTable, datasetKey, regFile, usedMethod] = ...
    build_TestBrake_sets(TestBrake, Roster, file, referencePhaseIdx, verbose)
% BUILD_TESTBRAKE_SETS_DATIREG
% Pair BC<->WV either (A) from a reference phase, or (B) from Roster metrics,
% persist pairing into a per-dataset file "DatiXX_reg.mat", and split TestBrake
% into per-pair sets (1 MBP + 1 BC + 1 WV) with ID-based flattening.
%
% Usage:
%   refPhase = 17;   % or NaN to force Roster-based
%   [sets, pairTbl, key, regFile, usedMethod] = build_TestBrake_sets_datireg(...
%         TestBrake, Roster, 'data/interim/Nodo_Dati08_20250701_20250703.mat', refPhase, true);
%
% Save-file behavior:
%   - If DatiXX_reg.mat exists AND UseReferencePhase==true → load pairing and DO NOT overwrite.
%   - Else:
%       • If referencePhaseIdx is valid → compute from reference phase, save with UseReferencePhase=true.
%       • If referencePhaseIdx is NaN/empty → compute from Roster, save with UseReferencePhase=false.

    if nargin < 5, verbose = true; end
    if isempty(TestBrake) || ~isstruct(TestBrake)
        error('TestBrake must be a non-empty struct array.');
    end
    if ~(ischar(file) || isstring(file))
        error('`file` must be a filename (char or string).');
    end

    % ---------- Derive dataset key + per-dataset registry ----------
    datasetKey = deriveDatasetKeyFromFilename(file);                % e.g., "Dati01"
    folderPath = pwd;                                               % current script folder
    regFile    = fullfile(folderPath, sprintf('%s_reg.mat', datasetKey));

    if verbose
        fprintf('[%s] Registry path: %s\n', mfilename, regFile);
    end
    % ---------- If saved pairing is "locked" by reference phase, use it ----------
    loadedPairing = [];
    loadedUseRef  = false;
    loadedRefIdx  = NaN;
    if isfile(regFile)
        S = load(regFile);
        if isfield(S, 'PairTable')
            loadedPairing = S.PairTable;
            if any(ismember(S.PairTable.Properties.VariableNames, 'UseReferencePhase'))
                loadedUseRef = any(S.PairTable.UseReferencePhase);
            end
            if any(ismember(S.PairTable.Properties.VariableNames, 'RefPhaseIdx'))
                loadedRefIdx = unique(S.PairTable.RefPhaseIdx);
            end
        end
    end

    if loadedUseRef
        if verbose
            fprintf('[%s] Using saved reference-phase pairing for %s (RefPhaseIdx=%s). No overwrite.\n', ...
                mfilename, datasetKey, mat2str(loadedRefIdx));
        end
        PairTable = loadedPairing;
        usedMethod   = "reference(saved)";
        % Build sets from saved pairing
        TestBrake_Sets = flattenSetsByPairing(TestBrake, PairTable, Roster, verbose);
        return;
    end

    % ---------- Decide pairing source for this run ----------
    useRefThisRun = isscalar(referencePhaseIdx) && ~isnan(referencePhaseIdx) ...
                    && referencePhaseIdx>=1 && referencePhaseIdx<=numel(TestBrake);

    if useRefThisRun
        % A) Pair from reference phase, then SAVE with UseReferencePhase=true (lock future runs)
        PairTable = computePairingFromReferencePhase(TestBrake, referencePhaseIdx);
        usedMethod   = "reference";
        if verbose
            fprintf('[%s] Computed pairing from reference phase %d for %s and locking registry.\n', ...
                mfilename, referencePhaseIdx, datasetKey);
        end
        saveRegFile(regFile, PairTable, file, true, referencePhaseIdx);
    else
        % B) Pair from Roster, then SAVE with UseReferencePhase=false (overwrite allowed)
        if ~isstruct(Roster) || ~isfield(Roster,'BC') || ~isfield(Roster,'WV')
            error('Roster must be a struct with fields BC and WV for Roster-based pairing.');
        end
        PairTable = computePairingFromRoster(TestBrake, Roster);
        usedMethod   = "roster";
        if verbose
            if isfile(regFile)
                fprintf('[%s] Roster-based pairing for %s. Overwriting %s\n', ...
                    mfilename, datasetKey, char(regFile));
            else
                fprintf('[%s] Roster-based pairing for %s. Creating %s\n', ...
                    mfilename, datasetKey, char(regFile));
            end
        end
        saveRegFile(regFile, PairTable, file, false, NaN);
    end

    % ---------- Build per-pair sets ----------
    TestBrake_Sets = flattenSetsByPairing(TestBrake, PairTable, Roster, verbose);
end

% ===================== Pairing strategies =====================

function PairTable = computePairingFromReferencePhase(TestBrake, refPhaseIdx)
% STRICT reference-phase pairing:
%   BC usable: ~isempty(Pressure) && SensorError==0
%   WV usable: ~isempty(Pressure) && WV_SensorError==0
%   (NormalBraking is ignored for eligibility.)
% Ranks: BC by MaxPressure (fallback max(Pressure)), WV by MeanPressure (fallback mean(Pressure))

    TBref = TestBrake(refPhaseIdx);
    mustHave(TBref,'BC'); mustHave(TBref,'WV');
    bcRef = TBref.BC;  wvRef = TBref.WV;
    if isempty(bcRef) || isempty(wvRef)
        error('Reference phase %d has empty BC or WV arrays.', refPhaseIdx);
    end

    % ---- strict usability masks ----
    bcUsable = arrayfun(@(b) ~isempty(sget(b,'Pressure',[])) ...
                             && (logical(sget(b,'SensorError',0))==0), bcRef(:));
    wvUsable = arrayfun(@(w) ~isempty(sget(w,'Pressure',[])) ...
                             && (logical(sget(w,'WV_SensorError',0))==0), wvRef(:));

    bcIdx = find(bcUsable);  wvIdx = find(wvUsable);
    if isempty(bcIdx) || isempty(wvIdx)
        error('Reference phase %d lacks usable BC or WV for pairing.', refPhaseIdx);
    end

    % ---- metrics (strict: prefer explicit fields, fallback to signal) ----
    bcMax = arrayfun(@(i) defaultMetric(bcRef(i), 'MaxPressure', 'Pressure', @max), bcIdx);
    wvAvg = arrayfun(@(i) defaultMetric(wvRef(i), 'MeanPressure','Pressure', @mean), wvIdx);

    [~, bcOrder] = sort(bcMax,'descend','MissingPlacement','last');
    [~, wvOrder] = sort(wvAvg,'descend','MissingPlacement','last');

    npairs    = min(numel(bcOrder), numel(wvOrder));
    bcUsedRef = bcIdx(bcOrder(1:npairs));
    wvUsedRef = wvIdx(wvOrder(1:npairs));

    % ---- stable IDs + labels ----
    bcID  = arrayfun(@(i) normalizeID(sget(bcRef(i),'ID',"")),   bcUsedRef, 'UniformOutput', false);
    wvID  = arrayfun(@(i) normalizeID(sget(wvRef(i),'ID',"")),   wvUsedRef, 'UniformOutput', false);
    bcLab = arrayfun(@(i) string(sget(bcRef(i),'Label',"")),     bcUsedRef);
    wvLab = arrayfun(@(i) string(sget(wvRef(i),'Label',"")),     wvUsedRef);
    bcMP  = arrayfun(@(i) defaultMetric(bcRef(i),'MaxPressure','Pressure',@max), bcUsedRef);
    wvMP  = arrayfun(@(i) defaultMetric(wvRef(i),'MeanPressure','Pressure',@mean), wvUsedRef);

    % ---- include flags in table ----
    useRef = true;
    refIdx = double(refPhaseIdx);

    PairTable = table( ...
        (1:npairs).', ...
        string(bcID(:)), bcMP(:), string(bcLab(:)), ...
        string(wvID(:)), wvMP(:), string(wvLab(:)), ...
        repmat(logical(useRef), npairs, 1), repmat(refIdx, npairs, 1), ...
        'VariableNames', { ...
            'PairIdx','BC_ID','BC_MaxPressure','BC_Label', ...
            'WV_ID','WV_MeanPressure','WV_Label', ...
            'UseReferencePhase','RefPhaseIdx' ...
        } ...
    );
end

function PairTable = computePairingFromRoster(TestBrake, Roster)
    bcList = Roster.BC(:);
    wvList = Roster.WV(:);
    if isempty(bcList), error('Roster.BC is empty.'); end
    if isempty(wvList), error('Roster.WV is empty.'); end

    bcIDs = arrayfun(@(b) normalizeID(sget(b,'ID',[])), bcList, 'UniformOutput', false);
    wvIDs = arrayfun(@(w) normalizeID(sget(w,'ID',[])), wvList, 'UniformOutput', false);
    bcMP  = arrayfun(@(b) sget(b,'MaxPressure',NaN), bcList);
    wvMP  = arrayfun(@(w) sget(w,'MeanPressure',NaN), wvList);

    [~, ordBC] = sort(bcMP, 'descend', 'MissingPlacement','last');
    [~, ordWV] = sort(wvMP, 'descend', 'MissingPlacement','last');

    npairs = min(numel(ordBC), numel(ordWV));
    if npairs == 0, error('No usable BC/WV pairs (Roster).'); end

    bcIDs_used = bcIDs(ordBC(1:npairs));
    wvIDs_used = wvIDs(ordWV(1:npairs));
    bcMP_used  = bcMP(ordBC(1:npairs));
    wvMP_used  = wvMP(ordWV(1:npairs));

    % Labels for readability (first appearance across phases)
    bcLabels_used = repmat("", npairs, 1);
    wvLabels_used = repmat("", npairs, 1);
    for p = 1:npairs
        bcLabels_used(p) = findLabelForID_in_TestBrake(TestBrake, 'BC', bcIDs_used{p});
        wvLabels_used(p) = findLabelForID_in_TestBrake(TestBrake, 'WV', wvIDs_used{p});
    end
    useRef  = false;
    refIdx  = NaN;
    PairTable = table( ...
        (1:npairs).', ...
        string(bcIDs_used(:)), bcMP_used(:), string(bcLabels_used(:)), ...
        string(wvIDs_used(:)), wvMP_used(:), string(wvLabels_used(:)), ...
        repmat(logical(useRef), npairs, 1), repmat(refIdx, npairs, 1), ...
        'VariableNames', { ...
        'PairIdx','BC_ID','BC_MaxPressure','BC_Label', ...
        'WV_ID','WV_MeanPressure','WV_Label', ...
        'UseReferencePhase','RefPhaseIdx' ...
        } ...
        );
end

% ===================== Saving/Loading helpers =====================

function saveRegFile(regFile, PairTable, sourceFile, useRef, refIdx)
% SAVEREGFILE  Save the PairTable (with added UseReferencePhase + RefPhaseIdx columns)
% to DatiXX_reg.mat for transparency.

    if ~ismember('UseReferencePhase', PairTable.Properties.VariableNames)
        PairTable.UseReferencePhase = repmat(logical(useRef), height(PairTable), 1);
    else
        PairTable.UseReferencePhase(:) = logical(useRef);
    end

    if ~ismember('RefPhaseIdx', PairTable.Properties.VariableNames)
        PairTable.RefPhaseIdx = repmat(refIdx, height(PairTable), 1);
    else
        PairTable.RefPhaseIdx(:) = refIdx;
    end

    % Meta info for debugging
    SourceFile = string(sourceFile);
    SavedOn    = datetime('now');

    try
        save(regFile, 'PairTable', 'SourceFile', 'SavedOn');
    catch ME
        warning('Failed to save registry file %s: %s', char(regFile), ME.message);
    end
end


% ===================== Flattening =====================

function TestBrake_Sets = flattenSetsByPairing(TestBrake, PairTable, Roster, verbose)
    if nargin < 4, verbose = true; end
    numPhases = numel(TestBrake);

    % MBP-only template (keep MBP_*; drop BC/WV arrays)
    mbpOnly = rmfield_ifexists(TestBrake, {'BC','WV'});
    templ   = addDefaultBCWVFields(mbpOnly(1));
    templ.PairIdx = NaN; templ.BC_ID = ""; templ.WV_ID = "";
    if isfield(Roster,'MBP_ID'), templ.MBP_ID = Roster.MBP_ID; else, templ.MBP_ID = ""; end
    templSet = repmat(templ, 1, numPhases);

    npairs = height(PairTable);
    TestBrake_Sets = cell(1, npairs);
    mbpFields = fieldnames(mbpOnly);

    for p = 1:npairs
        bcID = PairTable.BC_ID(p);
        wvID = PairTable.WV_ID(p);
        setP = templSet;

        for k = 1:numPhases
            % 1) copy MBP fields
            for ff = 1:numel(mbpFields)
                fn = mbpFields{ff}; setP(k).(fn) = mbpOnly(k).(fn);
            end
            % 2) meta
            setP(k).PairIdx = PairTable.PairIdx(p);
            setP(k).BC_ID   = bcID;
            setP(k).WV_ID   = wvID;

            % 3) flatten BC by ID
            idxBC = findRowByID(TestBrake(k), 'BC', bcID);
            if ~isnan(idxBC)
                b = TestBrake(k).BC(idxBC);
                setP(k).BC_Label               = string(sget(b,'Label',""));
                setP(k).BC_Time                = sget(b,'Time',[]);
                setP(k).BC_Pressure            = sget(b,'Pressure',[]);
                setP(k).BC_Pressure10hz        = sget(b,'Pressure10hz',[]);
                setP(k).BC_Gradient            = sget(b,'Gradient',[]);
                setP(k).BC_SensorError         = logical(sget(b,'SensorError',0));
                setP(k).BC_NormalBraking       = logical(sget(b,'NormalBraking',0));
                setP(k).BC_LowBraking          = logical(sget(b,'LowBraking',0));
                setP(k).BC_BadStart            = logical(sget(b,'BadStart',0));
                setP(k).BC_StartTime           = sget(b,'StartTime',[]);
                setP(k).BC_EndTime             = sget(b,'EndTime',[]);
                setP(k).BC_TestIndex           = sget(b,'TestIndex',NaN);
                setP(k).BC_Pressure_at_MBP_End = sget(b,'EndPressure',NaN);
                % NEW: pass through start-condition flags (backward-safe)
                setP(k).BC_StartAboveThresh    = logical(sget(b,'StartAboveThresh',false));
                setP(k).BC_FlatStartNearZero   = logical(sget(b,'FlatStartNearZero',false));
                setP(k).BC_AlreadyEngagedStart = logical(sget(b,'AlreadyEngagedStart',false));
                setP(k).BC_ReleasingAtStart    = logical(sget(b,'ReleasingAtStart',false));

                mp = sget(b,'MaxPressure',[]);
                pr = sget(b,'Pressure',[]);
                if isempty(mp), mp = iff(isempty(pr), NaN, max(pr)); end
                setP(k).BC_MaxPressure = mp;
            end

            % 4) flatten WV by ID
            idxWV = findRowByID(TestBrake(k), 'WV', wvID);
            if ~isnan(idxWV)
                w = TestBrake(k).WV(idxWV);
                setP(k).WV_Label        = string(sget(w,'Label',""));
                setP(k).WV_Time         = sget(w,'Time',[]);
                setP(k).WV_Pressure     = sget(w,'Pressure',[]);
                setP(k).WV_StartTime    = sget(w,'StartTime',[]);
                setP(k).WV_EndTime      = sget(w,'EndTime',[]);
                setP(k).WV_TestIndex    = sget(w,'TestIndex',NaN);
                setP(k).WV_SensorError  = logical(sget(w,'WV_SensorError',0));

                mp = sget(w,'MeanPressure',[]);
                pr = sget(w,'Pressure',[]);
                if isempty(mp), mp = iff(isempty(pr), NaN, mean(pr)); end
                setP(k).WV_MeanPressure = mp;
                ns = sget(w,'NumSamples',[]);
                if isempty(ns), ns = numel(pr); end
                setP(k).WV_NumSamples   = ns;
            end
        end

        TestBrake_Sets{p} = setP;
    end

    if verbose
        fprintf('[%s] Built %d sets (1 MBP + 1 BC + 1 WV) across %d phases.\n', ...
            mfilename, npairs, numPhases);
    end
end

% ===================== Small utilities (pure MATLAB) =====================

function mustHave(S, fn)
    if ~isfield(S, fn), error('Missing field: %s', fn); end
end

function out = rmfield_ifexists(S, names)
    f = fieldnames(S);
    names = intersect(names, f);
    if isempty(names), out = S; else, out = rmfield(S, names); end
end

function v = sget(S, fname, defaultVal)
    if isfield(S, fname) && ~isempty(S.(fname)), v = S.(fname);
    else, v = defaultVal; end
end

function x = defaultMetric(s, preferredField, fallbackField, aggFcn)
    v = sget(s, preferredField, []);
    if isempty(v)
        w = sget(s, fallbackField, []);
        x = iff(isempty(w), NaN, aggFcn(w));
    else
        x = v;
    end
end

function id = normalizeID(x)
    if isstring(x)
        id = x;
    elseif ischar(x)
        id = string(x);
    elseif isnumeric(x)
        if isscalar(x) && (abs(x - round(x)) < eps(max(1,abs(x))))
            id = string(sprintf('%.0f', x));
        else
            id = string(num2str(x, 17));
        end
    else
        id = string(jsonencode(x));
    end
end

function idx = findRowByID(TBphase, fname, targetID)
    idx = NaN;
    if ~isfield(TBphase, fname) || isempty(TBphase.(fname)), return; end
    A = TBphase.(fname);
    for i = 1:numel(A)
        if isfield(A(i),'ID')
            if normalizeID(A(i).ID) == targetID
                idx = i; return;
            end
        end
    end
end

function lbl = findLabelForID_in_TestBrake(TestBrake, fname, targetID)
    lbl = "";
    for k = 1:numel(TestBrake)
        idx = findRowByID(TestBrake(k), fname, targetID);
        if ~isnan(idx)
            lbl = string(sget(TestBrake(k).(fname)(idx),'Label',""));
            if ~strcmp(lbl,""), return; end
        end
    end
end

function key = deriveDatasetKeyFromFilename(file)
    [~, base, ~] = fileparts(char(file));
    tokens = regexp(base, 'Dati(\d+)', 'tokens', 'once');
    if isempty(tokens)
        [folderPath, ~, ~] = fileparts(char(file));
        [~, folderName] = fileparts(folderPath);
        tokens2 = regexp(folderName, 'Dati(\d+)', 'tokens', 'once');
        if isempty(tokens2), error('Cannot find DatiXX in "%s".', base);
        else, key = "Dati" + tokens2{1}; end
    else
        key = "Dati" + tokens{1};
    end
end

function T = addDefaultBCWVFields(T)
% ADDDEFAULTBCWVFIELDS  Initialize flattened BC_* and WV_* fields to defaults.
%
% This ensures every output struct has consistent fields
% even if the BC/WV stream is missing for a given phase.

% ---------- BC fields ----------
T.BC_Label               = "";
T.BC_Time                = [];
T.BC_Pressure            = [];
T.BC_Pressure10hz        = [];
T.BC_Gradient            = [];
T.BC_SensorError         = false;
T.BC_NormalBraking       = false;
T.BC_LowBraking          = false;
T.BC_BadStart            = false;

% NEW: explicit start-condition flags (default false)
T.BC_StartAboveThresh    = false;
T.BC_FlatStartNearZero   = false;
T.BC_AlreadyEngagedStart = false;
T.BC_ReleasingAtStart    = false;

T.BC_StartTime           = [];
T.BC_EndTime             = [];
T.BC_TestIndex           = NaN;
T.BC_ID                  = "";
T.BC_MaxPressure         = NaN;
T.BC_Pressure_at_MBP_End = NaN;

% ---------- WV fields ----------
T.WV_Label        = "";
T.WV_Time         = [];
T.WV_Pressure     = [];
T.WV_StartTime    = [];
T.WV_EndTime      = [];
T.WV_TestIndex    = NaN;
T.WV_ID           = "";
T.WV_MeanPressure = NaN;
T.WV_NumSamples   = NaN;
T.WV_SensorError  = false;
end


function out = iff(cond, a, b), if cond, out = a; else, out = b; end, end
