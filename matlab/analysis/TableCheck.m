clear
close all
clc
% issues = checkFeatureTable(TestBrake_Master);
load('TestBrake_Master.mat')
T = TestBrake_Master;

% Convert all cell-array variables to Hx1 numeric scalars
vars = string(T.Properties.VariableNames);      % <-- string scalars, safe for T.(v)

for v = vars(:)'                                % iterate string names
    if iscell(T.(v))
        H = height(T);
        y = nan(H,1);                           % preallocate

        for i = 1:H
            xi = T.(v){i};                      % cell content at row i

            if isempty(xi)
                y(i) = NaN;
            elseif isduration(xi)
                % duration -> seconds (numeric)
                if ~isempty(xi)
                    y(i) = seconds(xi(1));
                else
                    y(i) = NaN;
                end
            elseif isnumeric(xi) || islogical(xi)
                % numeric/logical -> first element
                y(i) = double(xi(1));
            else
                % other types (string/struct/table/etc.) -> NaN
                y(i) = NaN;
            end
        end

        T.(v) = y;                              % replace column with numeric vector
    end
end
% (Optional) re-check with your table checker
issues = checkFeatureTable(T);
%%
T = TestBrake_Master;   % or your table
vars = {'Total_Power_eff', 'Total_power_delay', ...
    'Buildup_end_pressure_delay', 'Release_start_pressure_delay'};

% Pressure binning
nBins = 4;                 % number of WV_MeanPressure bins
binMode = 'quantile';      % 'equalwidth' or 'quantile'

% X-axis group order (fixed 4 combos)
xCats = ["Standard | NonConsecutive", ...
    "Standard | Consecutive", ...
    "NonStandard | NonConsecutive", ...
    "NonStandard | Consecutive"];

% ================== PREP: PRESSURE BINS ==================
pressure = T.WV_MeanPressure;
isFiniteP = ~isnan(pressure) & isfinite(pressure);
P = pressure(isFiniteP);

if isempty(P)
    warning('All WV_MeanPressure are NaN/Inf. Binning disabled; all points will be excluded.');
end

switch lower(binMode)
    case 'quantile'
        % Use quantiles to balance counts
        % If not enough unique values for nBins, reduce bins
        uq = unique(P);
        if numel(uq) < nBins
            nBinsEff = max(1, numel(uq));
            warning('Reducing nBins from %d to %d due to limited unique pressures.', nBins, nBinsEff);
        else
            nBinsEff = nBins;
        end
        q = linspace(0,1,nBinsEff+1);
        edges = quantile(P, q);
        % Force strictly increasing edges (guard ties)
        edges = unique(edges);
        if numel(edges) < nBinsEff+1
            % pad tiny eps to make edges strictly increasing
            edges = edges + (0:numel(edges)-1)*eps(max(edges));
        end
        % Ensure rightmost edge includes max
        edges(end) = edges(end) + eps(edges(end));

    otherwise % 'equalwidth'
        if isempty(P)
            edges = [0 1]; % dummy
        else
            pmin = min(P); pmax = max(P);
            if pmin == pmax
                % Single value -> one bin
                edges = [pmin-0.5, pmax+0.5];
                nBins = 1;
            else
                edges = linspace(pmin, pmax, nBins+1);
            end
            edges(end) = edges(end) + eps(edges(end));
        end
end

% Build labels
if numel(edges) >= 2
    binLabels = strings(1, numel(edges)-1);
    for k = 1:numel(edges)-1
        binLabels(k) = sprintf('%.2f–%.2f', edges(k), edges(k+1));
    end
else
    binLabels = "All";
end

% Discretize to categorical bins
if numel(edges) >= 2
    pressureBins = discretize(pressure, edges);
    % Map to categorical with fixed category order
    g = categorical(pressureBins, 1:(numel(edges)-1), cellstr(binLabels));
    g = reordercats(g, cellstr(binLabels));
else
    g = categorical(repmat("All", height(T),1));
end

% ================== PREP: X-AXIS GROUPS ==================
brakeCat = categorical(T.Non_Standard_Braking, [0 1], {'Standard','NonStandard'});
pipeCat  = categorical(T.Consecutive_braking_pipe, [0 1], {'NonConsecutive','Consecutive'});

groupX = categorical(strcat(string(brakeCat), " | ", string(pipeCat)));
groupX = renamecats(groupX, categories(groupX), categories(groupX)); % no-op; ensures valid
% Force full set of 4 groups in fixed order
groupX = categorical(string(groupX), xCats, xCats, 'Ordinal', true);

% ================== PLOTTING ==================
figure('Name','Metrics by Braking Type','Color','w');
tiledlayout(2,2,'Padding','compact','TileSpacing','compact');

% Keep consistent colors across subplots
co = lines(max(3, numel(categories(g))));

for i = 1:numel(vars)
    nexttile;
    varName = vars{i};
    if ~ismember(varName, T.Properties.VariableNames)
        text(0.5,0.5,['Missing: ' varName],'HorizontalAlignment','center'); axis off;
        continue;
    end

    y = T.(varName);
    x = groupX;
    c = g;

    % Valid rows: y finite, x not missing, c not missing
    valid = ~isnan(y) & isfinite(y) & ~ismissing(x) & ~ismissing(c);
    y = y(valid); x = x(valid); c = c(valid);

    if isempty(y)
        text(0.5,0.5,['No data for ' varName],'HorizontalAlignment','center'); axis off;
        continue;
    end

    % Plot boxchart grouped by pressure bins (color)
    h = boxchart(x, y, 'GroupByColor', c);
    % Apply consistent colors per bin category
    catsC = categories(c);
    for k = 1:numel(catsC)
        set(h(k), 'BoxFaceColor', co(k,:), 'MarkerColor', co(k,:));
    end

    grid on;
    xlabel('Braking Type | Consecutive Pipe');
    ylabel(strrep(varName,'_',' '), 'Interpreter','none');
    title(strrep(varName,'_',' '));

    % Rotate ticks for readability
    xtickangle(20);

    % Legend outside right; only once per subplot (MATLAB creates one per)
    lg = legend(catsC, 'Location','northeastoutside');
    lg.Title.String = 'WV MeanPressure bins';
end

sgtitle('Metric Comparison by Braking Type, Consecutive Pipe, and WV MeanPressure Bins');

% Optional: tighten x-limits to existing categories
ax = findall(gcf,'Type','axes');
for k = 1:numel(ax)
    if isa(ax(k), 'matlab.graphics.axis.Axes')
        ax(k).XLimMode = 'auto';
    end
end
%%
function issues = checkFeatureTable(T)

if ~(istable(T) || istimetable(T))
    error('Input must be a table or timetable.');
end

H = height(T);
vn = T.Properties.VariableNames;

% Collector
rowsVar   = zeros(numel(vn),1);
colsVar   = zeros(numel(vn),1);
isScalar  = true(numel(vn),1);
isCell    = false(numel(vn),1);
cellMin   = nan(numel(vn),1);
cellMax   = nan(numel(vn),1);
cls       = strings(numel(vn),1);

for k = 1:numel(vn)
    x = T.(vn{k});
    cls(k) = string(class(x));

    % Size at variable level
    rowsVar(k) = size(x,1);
    colsVar(k) = size(x,2);

    if iscell(x)
        isCell(k) = true;
        % measure per-row "length" of each cell (0 for empty)
        try
            lens = cellfun(@(c) iCellLen(c), x);
        catch
            % some mixed-type cells: treat as non-scalar
            lens = nan(size(x));
        end
        cellMin(k) = min(lens, [], 'omitnan');
        cellMax(k) = max(lens, [], 'omitnan');
        isScalar(k) = all(lens == 1 | isnan(lens));  % scalar or treat NaNs as unknown
    else
        % numeric/logical/datetime/duration/categorical/string
        isScalar(k) = isvector(x) && size(x,2) == 1 && size(x,1) == H;
    end
end

% Basic problems
rowMismatch   = rowsVar ~= H;
wideNumeric   = (colsVar > 1) & ~isCell;  % e.g., HxN matrices or 1xN row vectors
cellVariedLen = isCell & (cellMin ~= cellMax); % cells with differing lengths per row

% Timetable checks
isBadTime = false;
hasDup    = false;
if istimetable(T)
    rt = T.Properties.RowTimes;
    isBadTime = ~issorted(rt);
    if ~isempty(rt)
        hasDup = any(diff(rt) == seconds(0));
    end
end

% Build report
issues = table(vn', cls, rowsVar, repmat(H,numel(vn),1), colsVar, ...
               isScalar, isCell, cellMin, cellMax, rowMismatch, wideNumeric, cellVariedLen, ...
               'VariableNames', {'VarName','Class','VarRows','TableRows','VarCols', ...
                                 'IsScalarPerRow','IsCell','CellLenMin','CellLenMax', ...
                                 'RowMismatch','IsWideNonCell','CellLenVaries'});

% Print concise diagnostics
fprintf('Table height (rows): %d\n', H);
bad = issues.RowMismatch | issues.IsWideNonCell | issues.CellLenVaries | ~issues.IsScalarPerRow;
if any(bad)
    disp('Problem variables:');
    disp(issues(bad, :));
else
    disp('All variables look like H×1 scalars per row with consistent lengths.');
end

if istimetable(T)
    if isBadTime, disp('Timetable row times are not sorted. Use: T = sortrows(T);'); end
    if hasDup,   disp('Timetable has duplicate row times. Consider: T = unique(T); or synchronize().'); end
end
end

% --- helper: length for a cell content (numeric/logical/char/string/datetime/duration) ---
function L = iCellLen(c)
if isempty(c)
    L = 0;
elseif isnumeric(c) || islogical(c) || isdatetime(c) || isduration(c) || isstring(c) || iscategorical(c)
    L = numel(c);
elseif ischar(c)
    L = numel(c);
else
    % unsupported nested type (struct/table/whatever): mark unknown
    L = NaN;
end
end
