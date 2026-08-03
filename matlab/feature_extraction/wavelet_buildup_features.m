function X = wavelet_buildup_features(X, Fs, waveletType, varargin)
% WAVELET_BUILDUP_FEATURES — works with TABLE or STRUCT ARRAY input.
% Adds resampled signals + wavelet features to each row/element.
%
% Required fields/vars:
%   Buildup_time_cyl, Buildup_pressure_cyl
%
% For TABLE:
%   - time/pressure can be cell columns; results are new table vars (cells/numbers).
% For STRUCT ARRAY:
%   - time/pressure are fields in each element; results are added as fields.

if nargin < 2 || isempty(Fs), Fs = 20; end
if nargin < 3 || isempty(waveletType), waveletType = 'db4'; end

p = inputParser;
p.addParameter('Levels', 4, @(x)isnumeric(x)&&isscalar(x)&&x>=1);
p.addParameter('DoCWT', false, @(x)islogical(x)||ismember(x,[0 1]));
p.addParameter('CWTBands', [], @(x)isnumeric(x)&&size(x,2)==2);
p.addParameter('MinSeconds', 1.0, @(x)isnumeric(x)&&isscalar(x)&&x>=0);
p.addParameter('Interp', 'pchip', @(x)ischar(x)||isstring(x));
p.parse(varargin{:});
Lv         = p.Results.Levels;
doCWT      = p.Results.DoCWT;
bands      = p.Results.CWTBands;
minSeconds = p.Results.MinSeconds;
interpMeth = char(p.Results.Interp);

% ---- Input type and basic checks ----
isTbl = istable(X);
isStr = isstruct(X);

if ~(isTbl || isStr)
    error('Input must be a table or struct array.');
end

if isTbl
    assert(ismember('Buildup_time_cyl', X.Properties.VariableNames), ...
        'Table must have variable Buildup_time_cyl');
    assert(ismember('Buildup_pressure_cyl', X.Properties.VariableNames), ...
        'Table must have variable Buildup_pressure_cyl');
    N = height(X);
else
    assert(isfield(X, 'Buildup_time_cyl'), 'Struct must have field Buildup_time_cyl');
    assert(isfield(X, 'Buildup_pressure_cyl'), 'Struct must have field Buildup_pressure_cyl');
    N = numel(X);
end

dt = 1/Fs;

% Default CWT bands if needed
if isempty(bands)
    nyq = 0.5*Fs;
    bands = [0   0.5; 0.5 2; 2 5; 5 0.9*nyq];
end
M = size(bands,1);

% --- Helpers to get/set per-item data without fragile comma lists ---
    function [t_raw, p_raw] = get_pair(idx)
        if isTbl
            % Table: allow either cell columns or direct vectors
            tcol = X.Buildup_time_cyl;
            pcol = X.Buildup_pressure_cyl;
            if iscell(tcol), t_raw = tcol{idx}; else, t_raw = tcol(idx,:); end
            if iscell(pcol), p_raw = pcol{idx}; else, p_raw = pcol(idx,:); end
        else
            % Struct array: fields per element
            t_raw = X(idx).Buildup_time_cyl;
            p_raw = X(idx).Buildup_pressure_cyl;
        end
    end

    function set_resampled(idx, t_uni, p_uni)
        if isTbl
            X.Resampled_time{idx,1}     = t_uni;
            X.Resampled_pressure{idx,1} = p_uni;
        else
            X(idx).Resampled_time     = t_uni;
            X(idx).Resampled_pressure = p_uni;
        end
    end

    function set_dwt(idx, detailE, approxE, entVal)
        if isTbl
            % Ensure columns exist once (on first assignment)
            if idx==1
                for lev = 1:Lv
                    vname = sprintf('DWT_Energy_D%d', lev);
                    if ~ismember(vname, X.Properties.VariableNames)
                        X.(vname) = NaN(N,1);
                    end
                end
                if ~ismember('DWT_Energy_A', X.Properties.VariableNames)
                    X.DWT_Energy_A = NaN(N,1);
                end
                if ~ismember('DWT_Entropy', X.Properties.VariableNames)
                    X.DWT_Entropy = NaN(N,1);
                end
            end
            for lev = 1:Lv
                vname = sprintf('DWT_Energy_D%d', lev);
                if lev <= numel(detailE)
                    X.(vname)(idx) = detailE(lev);
                else
                    X.(vname)(idx) = NaN;
                end
            end
            X.DWT_Energy_A(idx) = approxE;
            X.DWT_Entropy(idx)  = entVal;
        else
            % Struct: store in a sub-struct for tidiness
            X(idx).Wavelet.DWT_DetailEnergy = detailE(:).';
            X(idx).Wavelet.DWT_ApproxEnergy = approxE;
            X(idx).Wavelet.DWT_Entropy      = entVal;
        end
    end

    function set_cwt(idx, bandE)
        if isTbl
            % Create columns lazily with valid names
            for m = 1:M
                vname = matlab.lang.makeValidName( ...
                    sprintf('CWT_Energy_%g_%gHz', bands(m,1), bands(m,2)));
                if ~ismember(vname, X.Properties.VariableNames)
                    X.(vname) = NaN(N,1);
                end
                X.(vname)(idx) = bandE(m);
            end
        else
            X(idx).Wavelet.CWT_BandEnergy = bandE(:).';
            X(idx).Wavelet.CWT_BandsHz    = bands;
        end
    end
% --------------------------------------------------------------------

for i = 1:N
    [t_raw, p_raw] = get_pair(i);

    if isempty(t_raw) || isempty(p_raw) || numel(t_raw) ~= numel(p_raw)
        continue;
    end

    % Convert time to seconds from start
    if isdatetime(t_raw)
        t_sec = seconds(t_raw(:) - t_raw(1));
    else
        t_sec = t_raw(:) - t_raw(1);
    end
    p_raw = p_raw(:);

    good = isfinite(t_sec) & isfinite(p_raw);
    t_sec = t_sec(good); p_raw = p_raw(good);
    if numel(t_sec) < 2 || t_sec(end) < minSeconds
        continue;
    end

    % Ensure strictly increasing time
    [t_sec, uniqIdx] = unique(t_sec, 'stable');
    p_raw = p_raw(uniqIdx);

    % Resample to uniform grid
    t_uni = (0:dt:t_sec(end)).';
    if numel(t_sec) == 1
        p_uni = repmat(p_raw, numel(t_uni), 1);
    else
        p_uni = interp1(t_sec, p_raw, t_uni, interpMeth, 'extrap');
    end
    set_resampled(i, t_uni, p_uni);

    % --- DWT features ---
    % Decompose; adapt level if signal too short
    try
        [c,l] = wavedec(p_uni, Lv, waveletType);
        LvEff = Lv;
    catch
        LvEff = max(1, min(Lv, wmaxlev(numel(p_uni), waveletType)));
        [c,l] = wavedec(p_uni, LvEff, waveletType);
    end

    % Detail energies (D1..DLvEff), Approx energy (A_LvEff)
    detailE = NaN(1, LvEff);
    for lev = 1:LvEff
        Dj = detcoef(c, l, lev);
        detailE(lev) = sum(Dj.^2);
    end
    Acoef   = appcoef(c, l, waveletType, LvEff);
    approxE = sum(Acoef.^2);

    % Shannon entropy (fallback if toolbox fn missing)
    try
        entVal = wentropy(p_uni, 'shannon');
    catch
        px = abs(p_uni);
        px = px / (sum(px) + eps);
        entVal = -sum(px.*log(px+eps));
    end
    % Pad to requested Lv with NaN if LvEff < Lv
    if LvEff < Lv, detailE = [detailE, NaN(1, Lv-LvEff)]; end

    set_dwt(i, detailE, approxE, entVal);

    % --- Optional CWT band energies ---
    if doCWT
        try
            [cfs, f] = cwt(p_uni, Fs);    % cfs: (numScales x numTime)
            pTF = abs(cfs).^2;
            bandE = NaN(1, M);
            for m = 1:M
                rows = (f >= bands(m,1)) & (f <  bands(m,2));
                if any(rows)
                    bandE(m) = sum(pTF(rows,:), 'all');
                end
            end
            set_cwt(i, bandE);
        catch
            % leave unset if cwt unavailable
        end
    end
end
end
