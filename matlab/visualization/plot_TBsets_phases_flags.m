function hFig = plot_TBsets_phases_flags(TBsets_out, varargin)
% PLOT_TBSETS_PHASES_FLAGS_RASTER (Simplified)
% Accepts:
%   - Cell array: 1xN, each cell -> struct array of phases
%   - Struct array: 1xP or Px1 phases (single "cell")
%
% Subplot 1: MBP (blue/red) + BC (blue/red/black) + WV (purple)
% Subplot 2: Flag raster at phase mid-time.

    p = inputParser;
    p.addParameter('mbpCellIdx', 1, @(x) isnumeric(x) && isscalar(x) && x>=1);
    p.addParameter('assumeSecFromMBPStart', true, @(x) islogical(x) && isscalar(x));
    p.addParameter('plotFallbackWholeTrace', true, @(x) islogical(x) && isscalar(x));
    p.parse(varargin{:});
    mbpCellIdx = p.Results.mbpCellIdx;
    assumeSec  = p.Results.assumeSecFromMBPStart;

    % === NEW: normalize input to a cell array-of-struct-arrays ===
    TBcells = normalize_input(TBsets_out);
    nC = numel(TBcells);
    if mbpCellIdx > nC, error('mbpCellIdx exceeds number of cells.'); end

    % count phases
    nPerCell = zeros(1, nC);
    for c = 1:nC
        if ~isempty(TBcells{c}) && isstruct(TBcells{c})
            nPerCell(c) = numel(TBcells{c});
        else
            nPerCell(c) = 0;
        end
    end
    maxPhase = max(nPerCell);
    if maxPhase==0, error('No phases found.'); end

    % === figure & layout
    hFig = figure('Name','Braking + Flag Raster','Color','w');
    tl   = tiledlayout(hFig, 2, 1, 'TileSpacing','compact', 'Padding','compact');
    ax1  = nexttile(tl, 1); hold(ax1,'on'); grid(ax1,'on');
    ax2  = nexttile(tl, 2); hold(ax2,'on'); grid(ax2,'on');

    % === colors
    col_ok     = [0.00 0.45 0.74]; % blue
    col_err    = [0.85 0.10 0.10]; % red
    col_black  = [0.00 0.00 0.00]; % black (abnormal)
    col_wv     = [0.49 0.18 0.56]; % purple

    cmapCells    = lines(nC);
    colPhaseFlag = [0.2 0.2 0.2];

    phaseFlags = {'EmergencyBrake','SV_Error','Gateway_CB_Error','Gateway_VB_Error','GPS_SensorError'};
    cellFlags  = {'UB_Error','UR_Error','DS_Error','Non_Standard_Braking','BC_SensorError','WV_SensorError'};
    flagNames  = [phaseFlags, cellFlags];
    nFlags     = numel(flagNames);
    yMap = containers.Map(flagNames, num2cell(1:nFlags));

    % ------------- SUBPLOT 1: MBP + BC + WV -------------
    for phaseIdx = 1:maxPhase
        Smbp = fetchStruct(TBcells, mbpCellIdx, phaseIdx);
        [tStart, tEnd] = phase_time_window(Smbp, assumeSec);

        % MBP line
        if ~isempty(Smbp) && isfield(Smbp,'MBP_Time') && isfield(Smbp,'MBP_Pressure') ...
                && ~isempty(Smbp.MBP_Time) && ~isempty(Smbp.MBP_Pressure)

            t_mbp = normalize_time(Smbp.MBP_Time, Smbp, assumeSec);
            p_mbp = Smbp.MBP_Pressure(:);
            m_ok  = ~(isnan(p_mbp) | ismissing(p_mbp));
            t_mbp = t_mbp(m_ok); p_mbp = p_mbp(m_ok);

            if ~isempty(t_mbp)
                col_mbp = col_ok;
                if get_bool(Smbp,'SV_Error',false), col_mbp = col_err; end
                plot(ax1, t_mbp, p_mbp, '-', 'Color', col_mbp, 'LineWidth', 1.6);
            end
        end

        % BC line(s) from all cells
        for c = 1:nC
            S = fetchStruct(TBcells, c, phaseIdx);
            if isempty(S), continue; end

            col_bc = col_ok;
            if get_bool(S,'Non_Standard_Braking',false)
                col_bc = col_black; % highest priority
            elseif get_bool(S,'BC_SensorError',false)
                col_bc = col_err;
            end

            plot_cyl(ax1, S, 'BC_Time','BC_Pressure', col_bc, '-', assumeSec);
        end

        % WV (always purple, within MBP window)
        if ~isempty(tStart) && ~isempty(tEnd) && isdatetime(tStart) && isdatetime(tEnd)
            for c = 1:nC
                S = fetchStruct(TBcells, c, phaseIdx);
                if isempty(S) || ~isfield(S,'WV_Time') || ~isfield(S,'WV_Pressure'), continue; end
                t_wv = normalize_time(S.WV_Time, S, assumeSec);
                p_wv = S.WV_Pressure;
                if isempty(t_wv) || isempty(p_wv) || numel(t_wv)~=numel(p_wv), continue; end
                m = ~(isnan(p_wv) | ismissing(p_wv)) & t_wv>=tStart & t_wv<=tEnd;
                if any(m)
                    plot(ax1, t_wv(m), p_wv(m), '-', 'Color', col_wv, 'LineWidth', 1.2);
                end
            end
        end

        % ---------------- SUBPLOT 2: FLAG RASTER ----------------
        [tStart, tEnd, tMid] = phase_time_window_mid(Smbp, assumeSec);
        if isempty(tMid) || ~isdatetime(tMid), continue; end

        span_s     = max(1, seconds(tEnd - tStart));
        jitterStep = min(5, max(1, span_s/60));
        cellOffs   = ((1:nC) - (nC+1)/2) * jitterStep;

        % Phase-level flags (gray, from MBP cell only)
        for k = 1:numel(phaseFlags)
            fname = phaseFlags{k};
            if get_bool(Smbp, fname, false)
                y = yMap(fname);
                plot(ax2, tMid, y, 's', 'MarkerSize', 6, ...
                    'MarkerFaceColor', colPhaseFlag, 'MarkerEdgeColor','k', 'LineWidth', 0.5);
            end
        end

        % Cell-level flags (colored per cell)
        for c = 1:nC
            S = fetchStruct(TBcells, c, phaseIdx);
            if isempty(S), continue; end
            for k = 1:numel(cellFlags)
                fname = cellFlags{k};
                if get_bool(S, fname, false)
                    y = yMap(fname);
                    tPlot = tMid + seconds(cellOffs(c));
                    plot(ax2, tPlot, y, 'o', 'MarkerSize', 6, ...
                        'MarkerFaceColor', cmapCells(c,:), 'MarkerEdgeColor','k', 'LineWidth', 0.5);
                end
            end
        end
    end

    % cosmetics & link
    set(ax2, 'YLim', [0.5, nFlags+0.5], ...
         'YTick', 1:nFlags, 'YTickLabel', flagNames, 'TickLabelInterpreter','none');
    xlabel(ax1,'Time'); ylabel(ax1,'Pressure (bar)');
    title(ax1,'MBP, BC, WV (purple)');
    xlabel(ax2,'Time'); ylabel(ax2,'Flags');
    title(ax2,'Anomaly Flag');
    linkaxes([ax1, ax2], 'x');
    hold(ax1,'off'); hold(ax2,'off');

    % ---------------- helpers ----------------
    function TBcells = normalize_input(X)
        % Return a 1xN cell, each cell holds a struct array of phases.
        if isempty(X)
            error('TBsets_out is empty.');
        end
        if iscell(X)
            % validate cells contain struct arrays or are empty
            for ii = 1:numel(X)
                if ~isempty(X{ii}) && ~isstruct(X{ii})
                    error('TBsets_out{%d} must be a struct array of phases (or empty).', ii);
                end
            end
            TBcells = X;
            return;
        elseif isstruct(X)
            % Treat as a single "cell" with all phases
            TBcells = {X(:)'};  % row vector of structs
            return;
        else
            error('TBsets_out must be either a cell array of struct arrays or a struct array.');
        end
    end

    function S = fetchStruct(C, ci, pi)
        S = [];
        if ci<=numel(C) && ~isempty(C{ci}) && isstruct(C{ci}) && pi>=1 && pi<=numel(C{ci})
            S = C{ci}(pi);
        end
    end

    function tdt = normalize_time(t, S, assumeFlag)
        if isdatetime(t), tdt = t(:); return; end
        if isduration(t)
            if isfield(S,'MBP_StartTime') && isdatetime(S.MBP_StartTime)
                tdt = S.MBP_StartTime + t(:);
            else, tdt = datetime.empty(0,1);
            end
            return;
        end
        if isnumeric(t) && assumeFlag
            if isfield(S,'MBP_StartTime') && isdatetime(S.MBP_StartTime)
                tdt = S.MBP_StartTime + seconds(t(:));
            else, tdt = datetime.empty(0,1); end
            return;
        end
        tdt = datetime.empty(0,1);
    end

    function plot_cyl(axh, S, tField, pField, col, ls, assumeFlag)
        if ~isfield(S,tField) || ~isfield(S,pField), return; end
        t = S.(tField); p = S.(pField);
        if isempty(t) || isempty(p) || numel(t)~=numel(p), return; end
        tdt = normalize_time(t, S, assumeFlag);
        if isempty(tdt), return; end
        m = ~(isnan(p) | ismissing(p));
        if ~any(m), return; end
        plot(axh, tdt(m), p(m), 'LineWidth', 1.2, 'Color', col, 'LineStyle', ls);
    end

    function [tStart, tEnd] = phase_time_window(Smbp, assumeFlag)
        tStart = []; tEnd = [];
        if isempty(Smbp) || ~isstruct(Smbp), return; end
        if isfield(Smbp,'MBP_StartTime') && isdatetime(Smbp.MBP_StartTime), tStart = Smbp.MBP_StartTime; end
        if isfield(Smbp,'MBP_EndOfBrakeTime') && isdatetime(Smbp.MBP_EndOfBrakeTime), tEnd = Smbp.MBP_EndOfBrakeTime; end
        if (isempty(tStart) || isempty(tEnd)) && isfield(Smbp,'MBP_Time') && ~isempty(Smbp.MBP_Time)
            tVec = normalize_time(Smbp.MBP_Time, Smbp, assumeFlag);
            if isfield(Smbp,'MBP_StartIdx') && isnumeric(Smbp.MBP_StartIdx)
                tStart = tVec(min(max(1,Smbp.MBP_StartIdx),numel(tVec)));
            end
            if isfield(Smbp,'MBP_EndOfBrakeIdx') && isnumeric(Smbp.MBP_EndOfBrakeIdx)
                tEnd = tVec(min(max(1,Smbp.MBP_EndOfBrakeIdx),numel(tVec)));
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
        if isstruct(S) && isfield(S,f) && ~isempty(S.(f))
            x = S.(f);
            v = logical(x(1));
        end
    end
end
