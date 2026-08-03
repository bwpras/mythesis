function hFigs = plot_Diagnosis_RawPressure(TBsets_out, Nodo_filtered, varargin)
% PLOT_DIAGNOSIS_WITHNODOOVERLAY — plot diagnosis + overlay raw Nodo pressure in gray
%
% Subplot 1: raw Nodo (gray) + MBP/BC/WV from phase structs (colored)
% Subplot 2: selected diagnostic flags (raster) at phase midpoint.
%
% Inputs:
%   TBsets_out     — cell array of struct arrays (1xN cells) OR struct array of phases
%   Nodo_filtered  — struct array of raw sensor measurements (Time, Pressure, Sensor_Type)
%
% Options (Name-Value):
%   'mbpCellIdx'             (default 1)
%   'assumeSecFromMBPStart'  (default true)
%   'plotFallbackWholeTrace' (default true)
%
%   'flagNames'              (required) list of fields (strings/cellstr) to plot in raster
%   'phaseFlagNames'         (default empty): subset read from MBP cell only (gray squares)
%   'cellFlagNames'          (default empty): subset read from each cell (colored circles)
%
%   'overlayNodo'            (default true)
%   'overlayTypes'           (default ["MBP","BC","WV"]) which Sensor_Type to overlay
%   'overlayAlpha'           (default 0.25) if supported (R2023a+), else ignored
%   'overlayLineWidth'       (default 0.8)
%
% Output:
%   hFigs — vector of figure handles, one per unique day

    % ------------ parse inputs ------------
    p = inputParser;
    addRequired(p, 'TBsets_out', @(x) isstruct(x) || (iscell(x) && ~isempty(x)));
    addRequired(p, 'Nodo_filtered', @(x) isstruct(x) && ~isempty(x));

    addParameter(p, 'mbpCellIdx', 1, @(x) isnumeric(x)&&isscalar(x)&&x>=1);
    addParameter(p, 'assumeSecFromMBPStart', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'plotFallbackWholeTrace', true, @(x) islogical(x)&&isscalar(x));

    addParameter(p, 'flagNames', string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(p, 'phaseFlagNames', string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(p, 'cellFlagNames',  string.empty(0,1), @(x) isstring(x) || iscellstr(x) || ischar(x));

    addParameter(p, 'overlayNodo', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'overlayTypes', ["MBP","BC","WV"], @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(p, 'overlayAlpha', 0.25, @(x) isnumeric(x)&&isscalar(x)&&x>=0&&x<=1);
    addParameter(p, 'overlayLineWidth', 0.8, @(x) isnumeric(x)&&isscalar(x)&&x>0);

    parse(p, TBsets_out, Nodo_filtered, varargin{:});

    mbpCellIdx = p.Results.mbpCellIdx;
    assumeSec  = p.Results.assumeSecFromMBPStart;
    doFallback = p.Results.plotFallbackWholeTrace;

    flagNames      = string(p.Results.flagNames(:));
    phaseFlagNames = string(p.Results.phaseFlagNames(:));
    cellFlagNames  = string(p.Results.cellFlagNames(:));

    if isempty(flagNames)
        error("You must provide 'flagNames' (list of fields to plot).");
    end

    if isempty(phaseFlagNames) && isempty(cellFlagNames)
        cellFlagNames = flagNames;
    else
        phaseFlagNames = intersect(flagNames, phaseFlagNames, 'stable');
        cellFlagNames  = intersect(flagNames, cellFlagNames,  'stable');
    end

    doOverlay   = p.Results.overlayNodo;
    overlayTypes= string(p.Results.overlayTypes(:)');
    overlayA    = p.Results.overlayAlpha;
    overlayLW   = p.Results.overlayLineWidth;

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
    col_raw    = 0.65*[1 1 1];     % gray for Nodo overlay
    cmapCells  = lines(nC);
    colPhaseFlag = [0.2 0.2 0.2];

    % raster map
    nFlags = numel(flagNames);
    yMap = containers.Map(cellstr(flagNames), num2cell(1:nFlags));

    hFigs = gobjects(0);

    % Pre-index Nodo by Sensor_Type for speed
    NodoByType = groupNodoByType(Nodo_filtered);

    % ------------ per-day loop ------------
    for d = 1:numel(daySet)
        day0 = daySet(d);
        day1 = day0 + days(1);

        hFig = figure('Name', sprintf('Braking + Diagnosis + Nodo (%s)', datestr(day0,'yyyy-mm-dd')), ...
                      'Color','w');
        tl   = tiledlayout(hFig, 2, 1, 'TileSpacing','compact','Padding','compact');
        ax1  = nexttile(tl, 1); hold(ax1,'on'); grid(ax1,'on');
        ax2  = nexttile(tl, 2); hold(ax2,'on'); grid(ax2,'on');

        set([ax1 ax2],'TickLabelInterpreter','none');
        set(hFig, 'DefaultTextInterpreter','none','DefaultAxesTitleFontWeight','bold');

        anyPlotted = false;

        % ---- Overlay raw Nodo (gray), day-masked ----
        if doOverlay
            anyPlotted = plot_nodo_day(ax1, NodoByType, overlayTypes, day0, day1, col_raw, overlayLW, overlayA) || anyPlotted;
        end

        for phaseIdx = 1:maxPhase
            Smbp = fetchStruct(C, mbpCellIdx, phaseIdx);
            [tStart, tEnd, tMid] = phase_time_window_mid(Smbp, assumeSec);

            % ---- MBP from phase structs (day-masked) ----
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
        title(ax1, sprintf('Phase traces + raw Nodo overlay — %s', datestr(day0,'yyyy-mm-dd')), 'Interpreter','none');

        set(ax2, 'YLim', [0.5, nFlags+0.5], ...
                 'YTick', 1:nFlags, 'YTickLabel', cellstr(flagNames), ...
                 'TickLabelInterpreter','none',...
                 'YDir','reverse');
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


    % ================= helper functions =================

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

    function G = groupNodoByType(Nodo)
        % Returns a struct with fields MBP, BC, WV (if present), each is an array of indices
        G = struct();
        if ~isfield(Nodo,'Sensor_Type')
            return;
        end
        types = string({Nodo.Sensor_Type});
        u = unique(types);
        for i = 1:numel(u)
            t = u(i);
            if strlength(t)==0, continue; end
            G.(matlab.lang.makeValidName(char(t))) = find(types==t);
        end
    end

    function tf = plot_nodo_day(axh, NodoByType, typesWanted, day0, day1, col, lw, alphaVal)
        tf = false;

        % Use "Time" + "Pressure" from Nodo_filtered
        % Overlay all matching sensors for each type.
        for iType = 1:numel(typesWanted)
            tname = matlab.lang.makeValidName(char(typesWanted(iType)));
            if ~isfield(NodoByType, tname), continue; end
            idxList = NodoByType.(tname);

            for ii = 1:numel(idxList)
                Sraw = Nodo_filtered(idxList(ii));
                if ~isfield(Sraw,'Time') || ~isfield(Sraw,'Pressure'), continue; end
                tr = Sraw.Time(:);
                pr = Sraw.Pressure(:);
                if isempty(tr) || isempty(pr) || numel(tr)~=numel(pr), continue; end

                m = ~(isnan(pr) | ismissing(pr)) & (tr >= day0) & (tr < day1);
                if ~any(m), continue; end

                h = plot(axh, tr(m), pr(m), '-', 'Color', col, 'LineWidth', lw);

                % If your MATLAB supports RGBA in Color (recent releases), you can do:
                % set(h, 'Color', [col alphaVal]);
                % But this is not universal; so keep stable behavior by ignoring alpha.
                %#ok<NASGU>
                tf = true;
            end
        end
    end
end
