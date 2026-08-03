function hFigs = plot_TBsets_phases( S_or_cells, featureName, varargin )
% PLOT_TBSETS_PHASES — one figure per day (based on MBP_Time)
%
% Inputs:
%   S_or_cells  — struct array S(1×N) OR TBsets_out cell (1×nC)
%   featureName — scalar field to annotate in the lower panel
%
% Name-Value options:
%   'mbpCellIdx'             (default 1)
%   'assumeSecFromMBPStart'  (default true)
%   'plotFallbackWholeTrace' (default true)
%   'includeMBP_TPE'         (default false)
%   'annotatePhaseOnMBP'     (default true)  % annotate once per phase on MBP
%
% Output:
%   hFigs — vector of figure handles, one per unique day

    % ------------ parse inputs ------------
    p = inputParser;
    addRequired(p, 'S_or_cells', @(x) isstruct(x) || (iscell(x) && ~isempty(x)));
    addRequired(p, 'featureName', @(x) (ischar(x) || isstring(x)) );
    addParameter(p, 'mbpCellIdx', 1, @(x) isnumeric(x)&&isscalar(x)&&x>=1);
    addParameter(p, 'assumeSecFromMBPStart', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'plotFallbackWholeTrace', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'includeMBP_TPE', false, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'annotatePhaseOnMBP', true, @(x) islogical(x)&&isscalar(x));
    parse(p, S_or_cells, featureName, varargin{:});

    mbpCellIdx = p.Results.mbpCellIdx;
    assumeSec  = p.Results.assumeSecFromMBPStart;
    doFallback = p.Results.plotFallbackWholeTrace;
    includeMBP = p.Results.includeMBP_TPE;
    doAnnOnMBP = p.Results.annotatePhaseOnMBP;
    featureName = string(p.Results.featureName);

    % ------------ normalize representation ------------
    if isstruct(S_or_cells)
        C = {S_or_cells};        % wrap as 1 cell (new mode)
    else
        C = S_or_cells;          % legacy TBsets_out
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
    col_base_mbp = 0.5*[1 1 1];
    col_bld      = [0.00 0.45 0.74];
    col_hld      = [0.00 0.65 0.31];
    col_rel      = [0.85 0.33 0.10];
    col_wv       = [0.49 0.18 0.56];
    col_fp       = [0.4940 0.1840 0.5560];   % MATLAB default purple
    cmapCells    = lines(nC);

    warnedMultiVal = false;
    hFigs = gobjects(0);

    % ------------ per-day loop ------------
    for d = 1:numel(daySet)
        day0 = daySet(d);
        day1 = day0 + days(1);

        % figure & axes per day
        hFig = figure('Name', sprintf('Braking actions (%s) + %s', datestr(day0,'yyyy-mm-dd'), char(featureName)), ...
                      'Color','w');
        tl   = tiledlayout(hFig, 2, 1, 'TileSpacing','compact','Padding','compact');
        axMain = nexttile(tl,1); hold(axMain,'on'); grid(axMain,'on');
        axFeat = nexttile(tl,2); hold(axFeat,'on'); grid(axFeat,'on');

        % Keep underscores literal
        set([axMain axFeat],'TickLabelInterpreter','none');
        set(hFig, 'DefaultTextInterpreter','none','DefaultAxesTitleFontWeight','bold');

        anyPlotted = false;

        for phaseIdx = 1:maxPhase
            % MBP reference (per phase)
            Smbp = fetchStruct(C, mbpCellIdx, phaseIdx);
            [tStart, tEnd] = phase_time_window(Smbp, assumeSec);

            % ---- MBP curve (day-masked) ----
            if ~isempty(Smbp) && isfield(Smbp,'MBP_Time') && isfield(Smbp,'MBP_Pressure') ...
                    && ~isempty(Smbp.MBP_Time) && ~isempty(Smbp.MBP_Pressure)

                t_mbp = normalize_time(Smbp.MBP_Time, Smbp, assumeSec);
                p_mbp = Smbp.MBP_Pressure(:);
                m_ok  = ~(isnan(p_mbp) | ismissing(p_mbp));
                m_day = (t_mbp >= day0) & (t_mbp < day1) & m_ok;

                if any(m_day)
                    plot(axMain, t_mbp(m_day), p_mbp(m_day), '-', 'Color', col_base_mbp, 'LineWidth',1.2);
                    anyPlotted = true;
                end

                % highlight sub-phases (pipe) within this day
                TB = []; TH = []; TR = [];
                if isfield(Smbp,'Buildup_time_pipe') && ~isempty(Smbp.Buildup_time_pipe)
                    TB = normalize_time(Smbp.Buildup_time_pipe, Smbp, assumeSec);
                end
                if isfield(Smbp,'Holding_time_pipe') && ~isempty(Smbp.Holding_time_pipe)
                    TH = normalize_time(Smbp.Holding_time_pipe, Smbp, assumeSec);
                end
                if isfield(Smbp,'Release_time_pipe') && ~isempty(Smbp.Release_time_pipe)
                    TR = normalize_time(Smbp.Release_time_pipe, Smbp, assumeSec);
                end

                if ~isempty(TB)
                    mTB = ismember(t_mbp, TB) & (t_mbp >= day0) & (t_mbp < day1);
                    if any(mTB)
                        plot(axMain, t_mbp(mTB), p_mbp(mTB), '-', 'Color', col_bld, 'LineWidth',1.6);
                    end
                end
                if ~isempty(TH)
                    mTH = ismember(t_mbp, TH) & (t_mbp >= day0) & (t_mbp < day1);
                    if any(mTH)
                        plot(axMain, t_mbp(mTH), p_mbp(mTH), '-', 'Color', col_hld, 'LineWidth',1.6);
                    end
                end
                if ~isempty(TR)
                    mTR = ismember(t_mbp, TR) & (t_mbp >= day0) & (t_mbp < day1);
                    if any(mTR)
                        plot(axMain, t_mbp(mTR), p_mbp(mTR), '-', 'Color', col_rel, 'LineWidth',1.6);
                    end
                end
            end

            % ---- BC sub-phases / fallback (day-masked) ----
            for c = 1:nC
                S = fetchStruct(C, c, phaseIdx);
                if isempty(S), continue; end
                anyPlotted = plot_cyl_day(axMain, S, 'Buildup_time_cyl','Buildup_pressure_cyl', col_bld, '-', assumeSec, day0, day1) || anyPlotted;
                anyPlotted = plot_cyl_day(axMain, S, 'Holding_time_cyl','Holding_pressure_cyl', col_hld, '-', assumeSec, day0, day1) || anyPlotted;
                anyPlotted = plot_cyl_day(axMain, S, 'Release_time_cyl','Release_pressure_cyl', col_rel, '-', assumeSec, day0, day1) || anyPlotted;
                anyPlotted = plot_cyl_day(axMain, S, 'First_phase_time_cyl','First_phase_pressure_cyl', col_fp, '--', assumeSec, day0, day1) || anyPlotted;

                if doFallback && allEmpty(S, {'Buildup_time_cyl','Holding_time_cyl','Release_time_cyl'})
                    if isfield(S,'Brake_time_cyl') && isfield(S,'Brake_pressure_cyl')
                        anyPlotted = plot_cyl_day(axMain, S, 'Brake_time_cyl','Brake_pressure_cyl', 0.7*[1 1 1], '-', assumeSec, day0, day1) || anyPlotted;
                    elseif isfield(S,'BC_Time') && isfield(S,'BC_Pressure')
                        anyPlotted = plot_cyl_day(axMain, S, 'BC_Time','BC_Pressure', 0.7*[1 1 1], '-', assumeSec, day0, day1) || anyPlotted;
                    end
                end
            end

            % ---- WV overlay (day-masked) ----
            if ~isempty(tStart) && ~isempty(tEnd) && isdatetime(tStart) && isdatetime(tEnd)
                for c = 1:nC
                    S = fetchStruct(C, c, phaseIdx);
                    if isempty(S) || ~isfield(S,'WV_Time') || ~isfield(S,'WV_Pressure'), continue; end
                    t_wv = normalize_time(S.WV_Time, S, assumeSec);
                    p_wv = S.WV_Pressure;
                    if isempty(t_wv) || isempty(p_wv) || numel(t_wv)~=numel(p_wv), continue; end
                    m = ~(isnan(p_wv) | ismissing(p_wv)) & (t_wv >= day0) & (t_wv < day1);
                    if any(m)
                        plot(axMain, t_wv(m), p_wv(m), '-', 'Color', col_wv, 'LineWidth',1.2);
                        anyPlotted = true;
                    end
                end
            end

            % ---- Feature markers within this day ----
            [~, ~, tMid] = phase_time_window_mid(Smbp, assumeSec);
            if ~isempty(tMid) && isdatetime(tMid) && (tMid >= day0) && (tMid < day1)
                featVals   = [];
                featColors = [];

                if includeMBP
                    val_mbp = get_scalar_field(Smbp, featureName);
                    if ~isnan(val_mbp)
                        featVals   = [featVals; val_mbp];
                        featColors = [featColors; 0.2 0.2 0.2];
                    end
                end
                for c = 1:nC
                    S = fetchStruct(C, c, phaseIdx);
                    if isempty(S), continue; end
                    val_c = get_scalar_field(S, featureName);
                    if ~isnan(val_c)
                        featVals   = [featVals; val_c];
                        featColors = [featColors; cmapCells(c,:) ];
                    end
                end

                if ~isempty(featVals)
                    span_s     = max(1, seconds(min(tEnd,day1) - max(tStart,day0)));
                    jitterStep = min(5, max(1, span_s/60));
                    offsets    = ((1:numel(featVals)) - (numel(featVals)+1)/2)*jitterStep;
                    for k=1:numel(featVals)
                        tPlot = tMid + seconds(offsets(k));
                        if tPlot < day0 || tPlot >= day1, tPlot = min(max(tPlot, day0), day1 - seconds(1)); end
                        plot(axFeat, tPlot, featVals(k), 'o', 'MarkerSize',5, ...
                             'MarkerFaceColor', featColors(k,:), 'MarkerEdgeColor','k','LineWidth',0.5);
                        text(axFeat, tPlot, featVals(k), sprintf(' %.2g', featVals(k)), ...
                             'VerticalAlignment','bottom', 'HorizontalAlignment','left', ...
                             'Color', featColors(k,:), 'FontSize',9, 'FontWeight','bold', ...
                             'Interpreter','none'); % keep underscores literal
                    end
                end
            end

            % ---- Single annotation on MBP at phase midpoint ----
            if doAnnOnMBP && ~isempty(tMid) && isdatetime(tMid) && (tMid >= day0) && (tMid < day1)
                if ~isempty(Smbp) && isfield(Smbp,'MBP_Time') && isfield(Smbp,'MBP_Pressure') ...
                        && ~isempty(Smbp.MBP_Time) && ~isempty(Smbp.MBP_Pressure)

                    t_mbp = normalize_time(Smbp.MBP_Time, Smbp, assumeSec);
                    p_mbp = Smbp.MBP_Pressure(:);
                    m_day = ~(isnan(p_mbp)|ismissing(p_mbp)) & (t_mbp >= day0) & (t_mbp < day1);
                    if any(m_day)
                        idxDay   = find(m_day);
                        [~,kmin] = min(abs(t_mbp(idxDay) - tMid));
                        i0       = idxDay(kmin);
                        t0       = t_mbp(i0);
                        y0       = p_mbp(i0);

                        label = get_phase_label(Smbp);  % reads PhaseIdx
                        if strlength(label) > 0
                            yl = ylim(axMain); dy = 0.02*(yl(2)-yl(1));
                            text(axMain, t0, y0 + dy, sprintf('phase %s', label), ...
                                'Color',[0 0 0], 'FontSize',9, 'FontWeight','bold', ...
                                'BackgroundColor','w', 'Margin',1, 'Clipping','on', ...
                                'Interpreter','none');
                        end
                    end
                end
            end

        end % phase loop

        % labels / cosmetics
        % if nothing plotted, close and skip handle (avoid linkaxes on empty/invalid axes)
        if ~anyPlotted
            close(hFig);
            continue;  % go to next day
        end

        % labels / cosmetics (only if something was plotted)
        xlabel(axMain,'Time','Interpreter','none');
        ylabel(axMain,'Pressure (bar)','Interpreter','none');
        title(axMain, sprintf('MBP, BC, WV — %s', datestr(day0,'yyyy-mm-dd')), ...
            'Interpreter','none');

        xlabel(axFeat,'Time','Interpreter','none');
        ylabel(axFeat, char(featureName), 'Interpreter','none');
        title(axFeat, sprintf('%s — %s', char(featureName), datestr(day0,'yyyy-mm-dd')), ...
            'Interpreter','none');

        % link axes only when axes are valid and used
        if isgraphics(axMain) && isgraphics(axFeat)
            try
                linkaxes([axMain axFeat],'x');
            catch ME
                warning('linkaxes failed for day %s: %s', datestr(day0,'yyyy-mm-dd'), ME.message);
            end

        end

        hold(axMain,'off');
        hold(axFeat,'off');

        % store handle
        hFigs(end+1,1) = hFig; %#ok<AGROW>
    end % day loop

    % ------------ helpers ------------
    function S = fetchStruct(C, ci, pi)
        S = [];
        if ci<=numel(C) && ~isempty(C{ci}) && isstruct(C{ci}) && pi>=1 && pi<=numel(C{ci})
            S = C{ci}(pi);
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
        m = ~(isnan(p) | ismissing(p)) & (tdt >= day0) & (tdt < day1);
        if ~any(m), return; end
        plot(axh, tdt(m), p(m), 'LineWidth',1.0, 'Color',col, 'LineStyle',ls);
        tf = true;
    end

    function tf = allEmpty(S, fields)
        tf = true;
        for k = 1:numel(fields)
            f = fields{k};
            if isfield(S,f) && ~isempty(S.(f)), tf = false; return; end
        end
    end

    function [tStart, tEnd] = phase_time_window(Smbp, assumeFlag)
        tStart = []; tEnd = [];
        if isempty(Smbp) || ~isstruct(Smbp), return; end
        if isfield(Smbp,'MBP_StartTime') && isdatetime(Smbp.MBP_StartTime), tStart = Smbp.MBP_StartTime; end
        if isfield(Smbp,'MBP_EndOfBrakeTime') && isdatetime(Smbp.MBP_EndOfBrakeTime), tEnd = Smbp.MBP_EndOfBrakeTime; end
        if (isempty(tStart) || isempty(tEnd)) && isfield(Smbp,'MBP_Time') && ~isempty(Smbp.MBP_Time)
            tVec = normalize_time(Smbp.MBP_Time, Smbp, assumeFlag);
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

    function val = get_scalar_field(S, fldName)
        val = NaN;
        if ~isstruct(S) || ~isfield(S, fldName), return; end
        tp = S.(fldName);
        if isempty(tp), return; end
        if isscalar(tp) && isfinite(tp), val = tp; return; end
        idx = find(isfinite(tp), 1, 'first');
        if ~isempty(idx)
            val = tp(idx);
            if ~warnedMultiVal
                warning('Feature field ''%s'' is vector; using first finite value.', fldName);
                warnedMultiVal = true;
            end
        end
    end

    function out = iff(cond, a, b)
        if cond, out = a; else, out = b; end
    end

    function s = get_phase_label(S)
        s = "";
        if isfield(S,'PhaseIdx') && ~isempty(S.PhaseIdx)
            v = S.PhaseIdx;
            if isnumeric(v) && isscalar(v), s = string(v); return; end
            if ischar(v) || isstring(v),   s = string(v); return; end
        end
    end
end
