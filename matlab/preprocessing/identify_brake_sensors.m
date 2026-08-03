function [Nodo_out, rolesTable, steadyInfo] = identify_brake_sensors(Nodo, varargin)
% IDENTIFY_BRAKE_SENSORS — steady-window classifier with hard constraints
% Spec:
%   • LPF 1 Hz (Butter 4th, zero-phase) on a uniform 5 Hz grid
%   • Compute dP/dt (bar/s)
%   • Find contiguous "steady" regions where for ALL sensors:
%       |dP/dt| < 0.01  AND nearest raw sample ≤ 3 s
%   • Apply only on a steady region that contains any pressure > 4.6 bar
%   • Window can be short; if longer than 10 min, clip to 10 min around max pressure
%   • Classify by median pressure in that window:
%       > 4.6 → MBP,  < 0.2 → BC,  else → WV
%   • Enforce: exactly 1 MBP; equal numbers of WV and BC among the rest
%   • OUTPUT: same Nodo struct but with .Label, sorted: MBP first, WV next, BC last.
%   • If no candidate steady region is found, **skip** classification and
%     return original order with empty labels and an informative message.

% ---- parameters ----
p = inputParser;
addParameter(p,'FsGrid',5);
addParameter(p,'Fc',1);
addParameter(p,'GradTol',0.01);
addParameter(p,'MaxGapSec',3);
addParameter(p,'MaxWindowMin',10);
addParameter(p,'MinWindowSec',15);  % prefer blocks >= this (fallback allowed)
parse(p,varargin{:});
Fs       = p.Results.FsGrid;
Fc       = p.Results.Fc;
GradTol  = p.Results.GradTol;
MaxGap   = p.Results.MaxGapSec;
MaxWin   = p.Results.MaxWindowMin;
MinWin   = p.Results.MinWindowSec;

n = numel(Nodo);
if n==0, error('Empty Nodo.'); end

% ---- thin arrays & overlap window ----
ID = strings(n,1); T = cell(n,1); P = cell(n,1);
for k = 1:n
    ID(k) = string(Nodo(k).ID);
    t = Nodo(k).Time;       if isrow(t), t = t.'; end
    x = Nodo(k).Pressure;   if isrow(x), x = x.'; end
    good = ~isnat(t) & isfinite(x);
    t = t(good); x = x(good);

    % >>> NEW: enforce strictly increasing, unique time stamps
    if ~isempty(t)
        [t, ord] = sort(t, 'ascend');    % sort by time
        x = x(ord);
        [t, ia] = unique(t, 'stable');   % drop duplicates
        x = x(ia);
    end

    if numel(t) < 2
        % not enough points to interpolate linearly → graceful skip
        [Nodo_out, rolesTable, steadyInfo] = skip_and_fill_empty(Nodo, ID, ...
            sprintf('Sensor %s has <2 unique time samples.', ID(k)));
        return
    end

    T{k} = t; P{k} = x;
end

t0 = max(cellfun(@(t)t(1), T));
t1 = min(cellfun(@(t)t(end), T));
if isnat(t0) || isnat(t1) || t0>=t1
    [Nodo_out, rolesTable, steadyInfo] = skip_and_fill_empty(Nodo, ID, 'No temporal overlap across sensors.');
    return
end

% ---- grid & filter ----
dt = seconds(1/Fs);
tgrid = (t0:dt:t1).';  m = numel(tgrid);
Wn = Fc/(Fs/2);
if Wn>=1
    [Nodo_out, rolesTable, steadyInfo] = skip_and_fill_empty(Nodo, ID, 'Invalid LPF setup: Fc must be < Fs/2.');
    return
end
[b,a] = butter(4, Wn);

Pr = nan(m,n); Pf = nan(m,n); dP = nan(m,n); validNear = false(m,n);
t0s = seconds(tgrid - tgrid(1));

for k = 1:n
    % >>> NEW: re-assert sorted/unique before building timetable (extra safety)
    tk = T{k}; pk = P{k};
    [tk, ord] = sort(tk, 'ascend'); pk = pk(ord);
    [tk, ia]  = unique(tk, 'stable'); pk = pk(ia);

    % retime to grid (requires strictly monotonic times)
    TT  = timetable(tk, pk, 'VariableNames', {'P'});
    TT1 = retime(TT, tgrid, 'linear');
    y   = TT1.P; Pr(:,k) = y;

    % nearest-sample check ≤ MaxGap
    tkS = seconds(tk - tgrid(1));
    idxNear = round(interp1(tkS, (1:numel(tkS))', t0s, 'nearest', 'extrap'));
    idxNear = max(1, min(idxNear, numel(tkS)));
    validNear(:,k) = abs(t0s - tkS(idxNear)) <= MaxGap;

    % simple inpaint for filtering only (keep NaN after)
    yi = y;
    nanMask = isnan(yi);
    if any(nanMask)
        ii = find(~nanMask);
        if ~isempty(ii)
            yi(nanMask) = interp1(ii, yi(ii), find(nanMask), 'linear', 'extrap');
        end
    end

    if all(~isnan(yi))
        yf = filtfilt(b,a, yi);
    else
        yf = yi;
    end

    % restore NaN where not supported by raw neighborhood
    yf(~validNear(:,k)) = NaN;
    Pf(:,k) = yf;

    % gradient (bar/s)
    g = [0; diff(yf)] * Fs;
    bad = isnan(yf) | [false; isnan(yf(1:end-1))];
    g(bad) = NaN;
    dP(:,k) = g;
end

% ---- steady mask (all sensors must be steady & valid) ----
steadyPerSensor = (abs(dP) < GradTol) & validNear;
steadyAll = all(steadyPerSensor, 2);

% ---- find steady blocks that contain any P>4.6 ----
blocks = contiguous_blocks(steadyAll);
cand = [];
for b = 1:size(blocks,1)
    i1b = blocks(b,1); i2b = blocks(b,2);
    if seconds(tgrid(i2b)-tgrid(i1b)) < MinWin, continue; end
    seg = Pf(i1b:i2b, :);
    if any(seg(:) > 4.6)
        cand = [cand; i1b i2b]; %#ok<AGROW>
    end
end
if isempty(cand)
    % fallback: allow even shorter steady blocks if they contain P>4.6
    for b = 1:size(blocks,1)
        i1b = blocks(b,1); i2b = blocks(b,2);
        seg = Pf(i1b:i2b, :);
        if any(seg(:) > 4.6)
            cand = [cand; i1b i2b]; %#ok<AGROW>
        end
    end
end
if isempty(cand)
    % Graceful skip: no candidate steady window with P>4.6
    [Nodo_out, rolesTable, steadyInfo] = skip_and_fill_empty(Nodo, ID, ...
        'No steady window found that contains any pressure > 4.6 bar.');
    % Add basic context to steadyInfo
    steadyInfo.tgrid      = tgrid;
    steadyInfo.P_filtered = Pf;
    steadyInfo.dP_dt      = dP;
    steadyInfo.steadyAll  = steadyAll;
    return
end

% pick candidate with the longest duration
dur = cand(:,2) - cand(:,1) + 1;
[~, j] = max(dur);
i1 = cand(j,1); i2 = cand(j,2);

% clip to MaxWindowMin around time of maximum pressure within block
maxWinSamples = round(MaxWin * 60 * Fs);
segP = Pf(i1:i2, :);
[~, idxLocalMax] = max(max(segP, [], 2));
center = i1 + idxLocalMax - 1;
if (i2 - i1 + 1) > maxWinSamples
    half = floor(maxWinSamples/2);
    a = max(center - half, i1);
    b = min(a + maxWinSamples - 1, i2);
    i1 = a; i2 = b;
end
steadyMask = false(m,1); steadyMask(i1:i2) = true;

% ---- classification by median pressure in chosen steady window ----
MedianP = nan(n,1);
for k = 1:n
    pk = Pf(steadyMask, k);
    pk = pk(~isnan(pk));
    if isempty(pk), MedianP(k) = NaN; else, MedianP(k) = median(pk); end
end

roles = repmat("WV", n, 1);          % initial
roles(MedianP > 4.6) = "MBP";
roles(MedianP < 0.2) = "BC";
roles(~isfinite(MedianP)) = "Unknown";

% ---- enforce exactly ONE MBP ----
MBP_idx = find(roles=="MBP");
if isempty(MBP_idx)
    [~, imax] = max(MedianP);
    if isfinite(MedianP(imax))
        roles(imax) = "MBP";
        MBP_idx = imax;
    end
elseif numel(MBP_idx) > 1
    [~, jmax] = max(MedianP(MBP_idx));
    keep = MBP_idx(jmax);
    flip = setdiff(MBP_idx, keep);
    roles(flip) = "WV";
    MBP_idx = keep;
end

% ---- enforce equal BC and WV among the rest ----
rest = setdiff(1:n, MBP_idx);
isBC = roles(rest)=="BC";  isWV = roles(rest)=="WV";
numRest = numel(rest);
target = floor(numRest/2);  % target per class

% too many BC → move those closest to 0.2 up to WV
excessBC = sum(isBC) - target;
if excessBC > 0
    rc = rest(isBC);
    [~,ord] = sort(MedianP(rc),'descend','MissingPlacement','last');
    move = rc(ord(1:excessBC));
    roles(move) = "WV";
end
% too few BC → move WV with smallest MedianP down to BC
isBC = roles(rest)=="BC";
needBC = target - sum(isBC);
if needBC > 0
    rc = rest(roles(rest)=="WV");
    [~,ord] = sort(MedianP(rc),'ascend','MissingPlacement','last');
    move = rc(ord(1:needBC));
    roles(move) = "BC";
end

% ---- produce outputs: LABEL + SORTED Nodo ----
labelStr = cellstr(roles);  % cell array of char
% attach .Label to each entry
NodoL = Nodo;
for k = 1:n
    NodoL(k).Label = labelStr{k};
end

% sorting order: MBP first, WV next, BC last (Unknown, if any, appended at end)
MBP_idx = find(roles=="MBP");
WV_idx  = find(roles=="WV");
BC_idx  = find(roles=="BC");
UNK_idx = find(roles=="Unknown");

order = [MBP_idx(:); WV_idx(:); BC_idx(:); UNK_idx(:)];
Nodo_out = NodoL(order);

% ---- roles table (after sorting) ----
rolesTable = table(order, string({Nodo(order).ID})', string(labelStr(order)), MedianP(order), ...
    'VariableNames', {'OriginalIdx','ID','Label','MedianP_Steady'});

% ---- command-window output ----
fprintf('\n[identify_brake_sensors]\n');
fprintf('  Steady window used: %s  →  %s  (%.1f min)\n', ...
    datestr(tgrid(i1)), datestr(tgrid(i2)), seconds(tgrid(i2)-tgrid(i1))/60);
fprintf('  Grid Fs = %.1f Hz, LPF Fc = %.1f Hz, |dP/dt| < %.3f bar/s, MaxGap ≤ %.0f s\n', ...
    Fs, Fc, GradTol, MaxGap);
fprintf('  Classification by median pressure in steady window: >4.6=MBP, <0.2=BC, else=WV\n');
disp(rolesTable);

% ---- debug / plotting info ----
steadyInfo = struct();
steadyInfo.tgrid       = tgrid;
steadyInfo.P_filtered  = Pf;
steadyInfo.dP_dt       = dP;
steadyInfo.steadyAll   = steadyAll;
steadyInfo.steadyMask  = steadyMask;
steadyInfo.window_idx  = [i1 i2];
steadyInfo.window_time = [tgrid(i1) tgrid(i2)];
steadyInfo.MaxWindowMin= MaxWin;
steadyInfo.candidateFound = true;

end

% -------------------- helpers --------------------
function arr = contiguous_blocks(x)
% return [iStart iEnd] rows for each contiguous run of true in logical x
    x = x(:);
    if ~any(x), arr = zeros(0,2); return; end
    d = diff([false; x; false]);
    s = find(d==1);
    e = find(d==-1)-1;
    arr = [s e];
end

function [Nodo_out, rolesTable, steadyInfo] = skip_and_fill_empty(Nodo, ID, reason)
% Return original Nodo with empty .Label, empty-ish rolesTable, and message.
    n = numel(Nodo);
    Nodo_out = Nodo;
    for k = 1:n
        Nodo_out(k).Label = '';   % empty label as requested
    end
    rolesTable = table((1:n).', ID, repmat(string(''), n,1), repmat(NaN,n,1), ...
        'VariableNames', {'OriginalIdx','ID','Label','MedianP_Steady'});

    fprintf('\n[identify_brake_sensors] SKIPPED: %s\n', reason);
    if n>0
        t0 = Nodo(1).Time(1); t1 = Nodo(1).Time(end);
        if ~isnat(t0) && ~isnat(t1)
            fprintf('  Data span (sensor 1): %s → %s (%.1f h)\n', ...
                datestr(t0), datestr(t1), hours(t1 - t0));
        end
    end
    disp(rolesTable);

    steadyInfo = struct();
    steadyInfo.candidateFound = false;
    steadyInfo.reason = reason;
end
