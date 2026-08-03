function hFigs = plot_Diagnosis(TBsets_out, varargin)
% PLOT_DIAGNOSIS — one figure per day, MBP/BC/WV + selected flag raster
%
% Subplot 1: MBP (blue/red) + BC (blue/red/black) + WV (purple)
% Subplot 2: Raster of selected flags (binary/logical fields) at phase midpoint.
%
% Options (Name-Value):
%   'mbpCellIdx'            (default 1)
%   'assumeSecFromMBPStart' (default true)
%   'plotFallbackWholeTrace'(default true)
%
%   'flagNames'             (required) string/cellstr/char: flags to display (rows)
%   'phaseFlagNames'        (default empty): subset to read from MBP cell only (gray squares)
%   'cellFlagNames'         (default empty): subset to read from each cell (colored circles)
%       If phaseFlagNames/cellFlagNames are BOTH empty, all flagNames are treated as cell-level.
%
% Output:
%   hFigs — vector of figure handles, one per unique day

    % ------------ parse inputs ------------
    p = inputParser;
    addRequired(p, 'TBsets_out', @(x) isstruct(x) || (iscell(x) && ~isempty(x)));
    addParameter(p, 'mbpCellIdx', 1, @(x) isnumeric(x)&&isscalar(x)&&x>=1);
    addParameter(p, 'assumeSecFromMBPStart', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'plotFallbackWholeTrace', true, @(x) islogical(x)&&isscalar(x));

    addParameter(p, 'flagNames', string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(p, 'phaseFlagNames', string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(p, 'cellFlagNames',  string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));

    parse(p, TBsets_out, varargin{:});

    mbpCellIdx = p.Results.mbpCellIdx;
    assumeSec  = p.Results.assumeSecFromMBPStart;
    doFallback = p.Results.plotFallbackWholeTrace;

    flagNames      = string(p.Results.flagNames(:));
    phaseFlagNames = string(p.Results.phaseFlagNames(:));
    cellFlagNames  = string(p.Results.cellFlagNames(:));

    if isempty(flagNames)
        error("You must provide 'flagNames' (list of fields to plot).");
    end

    % If user didn't split phase/cell flags, treat everything as cell flags
    if isempty(phaseFlagNames) && isempty(cellFlagNames)
        cellFlagNames = flagNames;
    else
        % Ensure subsets are consistent with flagNames
        phaseFlagNames = intersect(flagNames, phaseFlagNames, 'stable');
        cellFlagNames  = intersect(flagNames, cellFlagNames,  'stable');
    end

    % ------------ normalize representation (baseline style) ------------
    if isstruct(TBsets_out)
        C = {TBsets_out(:)'};     % single cell, row vector of phases
    else
        C = TBsets_out;
    end

    nC = numel(C);
    if mbpCellIdx > nC, error('mbpCellIdx exceeds number of cells.'); end

    % Determine max number of phases across cells
    nPerCell = zeros(1,nC);
    for c = 1:nC
        if ~isempty(C{c}) && isstruct(C{c}), nPerCell(c) = numel(C{c}); end
    end
    maxPhase = max(nPerCell);
    if maxPhase == 0, error('No phases found.'); end

    % ------------ collect unique days from MBP_Time (chosen cell) ------------
    daySet = datetime.empty(0,1);
    for phaseIdx = 1:maxPhase
        Smbp = fetchStruct(C, mbpCellIdx, phaseIdx);
        if isempty(Smbp) || ~isfield(Smbp,'MBP_Time'), continue; end
        t_mbp = normalize_time(Smbp.MBP_Time, Smbp, assumeSec);
        if ~isempty(t_mbp)
            daysHere = unique(dateshift(t_mbp(~ismissing(t_mbp)), 'start', 'day'));
            daySet   = [daySet; daysHere]; %#ok<AGROW>
        end
    end
    if isempty(daySet)
        warning('No MBP_Time available to derive day partitions. Nothing to plot.');
        hFigs = gobjects(0); return;
    end
    daySet = unique(sort(daySet));

    % ------------ colors ------------
    col_ok     = [0.00 0.45 0.74]; % blue
    col_err    = [0.85 0.10 0.10]; % red
    col_black  = [0.00 0.00 0.00]; % black (abnormal)
    col_wv     = [0.49 0.18 0.56]; % purple
    cmapCells  = lines(nC);
    colPhaseFlag = [0.2 0.2 0.2];

    % raster map
    nFlags = numel(flagNames);
    yMap = containers.Map(cellstr(flagNames), num2cell(1:nFlags));

    hFigs = gobjects(0);

    % ------------ per-day loop ------------
    for d = 1:numel(daySet)
        day0 = daySet(d);
        day1 = day0 + days(1);

        hFig = figure('Name', sprintf('Braking + Diagnosis (%s)', datestr(day0,'yyyy-mm-dd')), ...
                      'Color','w');
        tl   = tiledlayout(hFig, 2, 1, 'TileSpacing','compact','Padding','compact');
        ax1  = nexttile(tl, 1); hold(ax1,'on'); grid(ax1,'on');
        ax2  = nexttile(tl, 2); hold(ax2,'on'); grid(ax2,'on');

        set([ax1 ax2],'TickLabelInterpreter','none');
        set(hFig, 'DefaultTextInterpreter','none','DefaultAxesTitleFontWeight','bold');

        anyPlotted = false;

        for phaseIdx = 1:maxPhase
            Smbp = fetchStruct(C, mbpCellIdx, phaseIdx);
            [tStart, tEnd, tMid] = phase_time_window_mid(Smbp, assumeSec);

            % ---- MBP (day-masked) ----
            if ~isempty(Smbp) && isfield(Smbp,'MBP_Time') && isfield(Smbp,'MBP_Pressure') ...
                    && ~isempty(Smbp.MBP_Time) && ~isempty(Smbp.MBP_Pressure)

                t_mbp = normalize_time(Smbp.MBP_Time, Smbp, assumeSec);
                p_mbp = Smbp.MBP_Pressure(:);
                m_ok  = ~(isnan(p_mbp) | ismissing(p_mbp));
                m_day = (t_mbp >= day0) & (t_mbp < day1) & m_ok;

                if any(m_day)
                    col_mbp = col_ok;
                    if get_bool(Smbp,'SV_Error',false), col_mbp = col_err; end
                    plot(ax1, t_mbp(m_day), p_mbp(m_day), '-', 'Color', col_mbp, 'LineWidth',1.6);
                    anyPlotted = true;
                end
            end

            % ---- BC from all cells (day-masked) ----
            for c = 1:nC
                S = fetchStruct(C, c, phaseIdx);
                if isempty(S), continue; end

                col_bc = col_ok;
                if get_bool(S,'Non_Standard_Braking',false)
                    col_bc = col_black;
                elseif get_bool(S,'BC_SensorError',false)
                    col_bc = col_err;
                end

                anyPlotted = plot_cyl_day(ax1, S, 'BC_Time','BC_Pressure', col_bc, '-', assumeSec, day0, day1) || anyPlotted;

                if doFallback && isfield(S,'Brake_time_cyl') && isfield(S,'Brake_pressure_cyl')
                    anyPlotted = plot_cyl_day(ax1, S, 'Brake_time_cyl','Brake_pressure_cyl', col_bc, '-', assumeSec, day0, day1) || anyPlotted;
                end
            end

            % ---- WV (within MBP window + day-masked) ----
            if ~isempty(tStart) && ~isempty(tEnd) && isdatetime(tStart) && isdatetime(tEnd)
                for c = 1:nC
                    S = fetchStruct(C, c, phaseIdx);
                    if isempty(S) || ~isfield(S,'WV_Time') || ~isfield(S,'WV_Pressure'), continue; end
                    t_wv = normalize_time(S.WV_Time, S, assumeSec);
                    p_wv = S.WV_Pressure(:);
                    if isempty(t_wv) || isempty(p_wv) || numel(t_wv)~=numel(p_wv), continue; end
                    m = ~(isnan(p_wv) | ismissing(p_wv)) & (t_wv >= day0) & (t_wv < day1) & (t_wv>=tStart) & (t_wv<=tEnd);
                    if any(m)
                        plot(ax1, t_wv(m), p_wv(m), '-', 'Color', col_wv, 'LineWidth',1.2);
                        anyPlotted = true;
                    end
                end
            end

            % ---- Raster at phase midpoint ----
            if isempty(tMid) || ~isdatetime(tMid) || tMid < day0 || tMid >= day1
                continue;
            end

            span_s     = max(1, seconds(tEnd - tStart));
            jitterStep = min(5, max(1, span_s/60));
            cellOffs   = ((1:nC) - (nC+1)/2) * jitterStep;

            % Phase flags (MBP only, gray squares)
            for k = 1:numel(phaseFlagNames)
                fname = phaseFlagNames(k);
                if get_bool(Smbp, fname, false)
                    y = yMap(char(fname));
                    plot(ax2, tMid, y, 's', 'MarkerSize', 6, ...
                        'MarkerFaceColor', colPhaseFlag, 'MarkerEdgeColor','k', 'LineWidth', 0.5);
                end
            end

            % Cell flags (colored circles)
            for c = 1:nC
                S = fetchStruct(C, c, phaseIdx);
                if isempty(S), continue; end
                for k = 1:numel(cellFlagNames)
                    fname = cellFlagNames(k);
                    if get_bool(S, fname, false)
                        y = yMap(char(fname));
                        tPlot = tMid + seconds(cellOffs(c));
                        plot(ax2, tPlot, y, 'o', 'MarkerSize', 6, ...
                            'MarkerFaceColor', cmapCells(c,:), 'MarkerEdgeColor','k', 'LineWidth', 0.5);
                    end
                end
            end
        end % phase loop

        if ~anyPlotted
            close(hFig);
            continue;
        end

        % ---- cosmetics ----
        xlabel(ax1,'Time','Interpreter','none');
        ylabel(ax1,'Pressure (bar)','Interpreter','none');
        title(ax1, sprintf('MBP, BC, WV — %s', datestr(day0,'yyyy-mm-dd')), 'Interpreter','none');

        set(ax2, 'YLim', [0.5, nFlags+0.5], ...
                 'YTick', 1:nFlags, 'YTickLabel', cellstr(flagNames), ...
                 'TickLabelInterpreter','none');
        xlabel(ax2,'Time','Interpreter','none');
        ylabel(ax2,'Flags','Interpreter','none');
        title(ax2, sprintf('Selected diagnostic flags — %s', datestr(day0,'yyyy-mm-dd')), 'Interpreter','none');

        try
            linkaxes([ax1, ax2], 'x');
        catch
        end

        hold(ax1,'off'); hold(ax2,'off');
        hFigs(end+1,1) = hFig; %#ok<AGROW>
    end % day loop


    % ---------------- helpers ----------------
    function S = fetchStruct(Ccells, ci, pi)
        S = [];
        if ci<=numel(Ccells) && ~isempty(Ccells{ci}) && isstruct(Ccells{ci}) && pi>=1 && pi<=numel(Ccells{ci})
            S = Ccells{ci}(pi);
        end
    end

    function tdt = normalize_time(t, S, assumeFlag)
        if isdatetime(t), tdt = t(:); return; end
        if isduration(t)
            t0 = pick_anchor_time(S);
            tdt = iff(~isempty(t0), t0 + t(:), datetime.empty(0,1)); return;
        end
        if isnumeric(t) && assumeFlag
            t0 = pick_anchor_time(S);
            tdt = iff(~isempty(t0), t0 + seconds(t(:)), datetime.empty(0,1)); return;
        end
        tdt = datetime.empty(0,1);
    end

    function t0 = pick_anchor_time(S)
        t0 = [];
        if isfield(S,'MBP_StartTime') && isdatetime(S.MBP_StartTime) && ~isempty(S.MBP_StartTime)
            t0 = S.MBP_StartTime; return;
        end
        if isfield(S,'MBP_Time') && ~isempty(S.MBP_Time) && isdatetime(S.MBP_Time)
            tmbp = S.MBP_Time(:); tmbp = tmbp(~ismissing(tmbp));
            if ~isempty(tmbp), t0 = tmbp(1); end
        end
    end

    function tf = plot_cyl_day(axh, S, tField, pField, col, ls, assumeFlag, day0, day1)
        tf = false;
        if ~isfield(S,tField) || ~isfield(S,pField), return; end
        t = S.(tField); p = S.(pField);
        if isempty(t) || isempty(p) || numel(t)~=numel(p), return; end
        tdt = normalize_time(t, S, assumeFlag);
        if isempty(tdt), return; end
        p = p(:);
        m = ~(isnan(p) | ismissing(p)) & (tdt >= day0) & (tdt < day1);
        if ~any(m), return; end
        plot(axh, tdt(m), p(m), 'LineWidth',1.2, 'Color',col, 'LineStyle',ls);
        tf = true;
    end

    function [tStart, tEnd] = phase_time_window(Smbp, assumeFlag)
        tStart = []; tEnd = [];
        if isempty(Smbp) || ~isstruct(Smbp), return; end
        if isfield(Smbp,'MBP_StartTime') && isdatetime(Smbp.MBP_StartTime), tStart = Smbp.MBP_StartTime; end
        if isfield(Smbp,'MBP_EndOfBrakeTime') && isdatetime(Smbp.MBP_EndOfBrakeTime), tEnd = Smbp.MBP_EndOfBrakeTime; end
        if (isempty(tStart) || isempty(tEnd)) && isfield(Smbp,'MBP_Time') && ~isempty(Smbp.MBP_Time)
            tVec = normalize_time(Smbp.MBP_Time, Smbp, assumeFlag);
            if isempty(tVec), return; end
            if isempty(tStart)
                if isfield(Smbp,'MBP_StartIdx') && isnumeric(Smbp.MBP_StartIdx) ...
                        && Smbp.MBP_StartIdx>=1 && Smbp.MBP_StartIdx<=numel(tVec)
                    tStart = tVec(Smbp.MBP_StartIdx);
                else
                    tStart = tVec(1);
                end
            end
            if isempty(tEnd)
                if isfield(Smbp,'MBP_EndOfBrakeIdx') && isnumeric(Smbp.MBP_EndOfBrakeIdx) ...
                        && Smbp.MBP_EndOfBrakeIdx>=1 && Smbp.MBP_EndOfBrakeIdx<=numel(tVec)
                    tEnd = tVec(Smbp.MBP_EndOfBrakeIdx);
                else
                    tEnd = tVec(end);
                end
            end
        end
    end

    function [tStart, tEnd, tMid] = phase_time_window_mid(Smbp, assumeFlag)
        [tStart, tEnd] = phase_time_window(Smbp, assumeFlag);
        tMid = [];
        if ~isempty(tStart) && ~isempty(tEnd) && isdatetime(tStart) && isdatetime(tEnd)
            tMid = tStart + (tEnd - tStart)/2;
        end
    end

    function v = get_bool(S, f, defaultVal)
        v = defaultVal;
        if ~isstruct(S) || ~isfield(S, f) || isempty(S.(f)), return; end
        x = S.(f);
        if islogical(x), v = logical(x(1)); return; end
        if isnumeric(x), v = logical(x(1)); return; end
        if isstring(x) || ischar(x)
            xs = lower(string(x(1)));
            if xs=="true" || xs=="1", v = true;
            elseif xs=="false" || xs=="0", v = false;
            end
            return;
        end
        if iscategorical(x)
            xs = lower(string(x(1)));
            if xs=="true" || xs=="1", v = true;
            elseif xs=="false" || xs=="0", v = false;
            end
        end
    end

    function out = iff(cond, a, b)
        if cond, out = a; else, out = b; end
    end
end
