function hFigs = plot_PhaseClassification_fp(S_or_cells, varargin)
% plot_PhaseClassification_fp
% Plots:
%   - First_phase_time / First_phase_pressure          (SOLID)  -> 10 Hz
%   - First_phase_time_1hz / First_phase_pressure_1hz  (DASHED) -> 1 Hz filtered
%
% Single Y-axis: BC Pressure [bar]

    % ------------ parse inputs ------------
    p = inputParser;
    addRequired(p, 'S_or_cells', @(x) isstruct(x) || (iscell(x) && ~isempty(x)));
    addParameter(p, 'oneFigurePerPhase', true, @(x) islogical(x)&&isscalar(x));
    addParameter(p, 'lineWidth', 1.5, @(x) isnumeric(x)&&isscalar(x)&&x>0);
    parse(p, S_or_cells, varargin{:});

    onePerPhase = p.Results.oneFigurePerPhase;
    lw          = p.Results.lineWidth;

    % ------------ normalize representation ------------
    if isstruct(S_or_cells)
        Sarr = S_or_cells;
    else
        Sarr = [];
        for k = 1:numel(S_or_cells)
            if ~isempty(S_or_cells{k}) && isstruct(S_or_cells{k})
                Sarr = S_or_cells{k};
                break;
            end
        end
        if isempty(Sarr)
            warning('No struct found inside the cell input.');
            hFigs = gobjects(0);
            return;
        end
    end

    % Validate required fields
    if ~isfield(Sarr,'First_phase_time') || ...
       ~isfield(Sarr,'First_phase_pressure')
        error('Missing First_phase_time or First_phase_pressure.');
    end

    col_10hz = [0.4940 0.1840 0.5560]; % purple
    col_1hz  = [0 0 0];               % black dashed

    hFigs = gobjects(0);

    % ============================================================
    % =================== SINGLE FIGURE MODE =====================
    % ============================================================
    if ~onePerPhase

        hFig = figure('Name','BC First Phase: 10 Hz vs 1 Hz','Color','w');
        ax = axes(hFig); hold(ax,'on'); grid(ax,'on');
        set(ax,'TickLabelInterpreter','none');

        legendAdded10 = false;
        legendAdded1  = false;
        anyPlotted    = false;

        for i = 1:numel(Sarr)

            % ---------- 10 Hz (SOLID) ----------
            t10 = Sarr(i).First_phase_time;
            p10 = Sarr(i).First_phase_pressure;

            if ~isempty(t10) && ~isempty(p10) && ...
               isdatetime(t10) && numel(t10)==numel(p10)

                m10 = ~(isnan(p10) | ismissing(p10) | ismissing(t10));

                if any(m10)
                    if ~legendAdded10
                        plot(ax, t10(m10), p10(m10), '-', ...
                            'Color', col_10hz, 'LineWidth', lw, ...
                            'DisplayName','10 Hz');
                        legendAdded10 = true;
                    else
                        plot(ax, t10(m10), p10(m10), '-', ...
                            'Color', col_10hz, 'LineWidth', lw, ...
                            'HandleVisibility','off');
                    end
                    anyPlotted = true;
                end
            end

            % ---------- 1 Hz FILTERED (DASHED) ----------
            if isfield(Sarr,'First_phase_time_1hz') && ...
               isfield(Sarr,'First_phase_pressure_1hz')

                t1 = Sarr(i).First_phase_time_1hz;
                p1 = Sarr(i).First_phase_pressure_1hz;

                if ~isempty(t1) && ~isempty(p1) && ...
                   isdatetime(t1) && numel(t1)==numel(p1)

                    m1 = ~(isnan(p1) | ismissing(p1) | ismissing(t1));

                    if any(m1)
                        if ~legendAdded1
                            plot(ax, t1(m1), p1(m1), '--', ...
                                'Color', col_1hz, 'LineWidth', lw, ...
                                'DisplayName','1 Hz (filtered)');
                            legendAdded1 = true;
                        else
                            plot(ax, t1(m1), p1(m1), '--', ...
                                'Color', col_1hz, 'LineWidth', lw, ...
                                'HandleVisibility','off');
                        end
                        anyPlotted = true;
                    end
                end
            end

        end

        if ~anyPlotted
            close(hFig);
            warning('Nothing plotted.');
            return;
        end

        legend(ax,'Location','best');
        xlabel(ax,'Time','Interpreter','none');
        ylabel(ax,'BC Pressure [bar]','Interpreter','none');
        title(ax,'BC First Phase: 10 Hz (solid) vs 1 Hz (dashed)','Interpreter','none');

        hFigs = hFig;

    % ============================================================
    % =================== ONE FIGURE PER PHASE ===================
    % ============================================================
    else

        for i = 1:numel(Sarr)

            hFig = figure('Name',sprintf('BC Phase %d',i),'Color','w');
            ax = axes(hFig); hold(ax,'on'); grid(ax,'on');
            set(ax,'TickLabelInterpreter','none');

            anyPlotted = false;

            % 10 Hz
            t10 = Sarr(i).First_phase_time;
            p10 = Sarr(i).First_phase_pressure;

            if ~isempty(t10) && ~isempty(p10) && ...
               isdatetime(t10) && numel(t10)==numel(p10)

                m10 = ~(isnan(p10) | ismissing(p10) | ismissing(t10));
                if any(m10)
                    plot(ax, t10(m10), p10(m10), '-', ...
                        'Color', col_10hz, 'LineWidth', lw);
                    anyPlotted = true;
                end
            end

            % 1 Hz
            if isfield(Sarr,'First_phase_time_1hz') && ...
               isfield(Sarr,'First_phase_pressure_1hz')

                t1 = Sarr(i).First_phase_time_1hz;
                p1 = Sarr(i).First_phase_pressure_1hz;

                if ~isempty(t1) && ~isempty(p1) && ...
                   isdatetime(t1) && numel(t1)==numel(p1)

                    m1 = ~(isnan(p1) | ismissing(p1) | ismissing(t1));
                    if any(m1)
                        plot(ax, t1(m1), p1(m1), '--', ...
                            'Color', col_1hz, 'LineWidth', lw);
                        anyPlotted = true;
                    end
                end
            end

            if ~anyPlotted
                close(hFig);
                continue;
            end

            legend(ax,{'10 Hz','1 Hz (filtered)'},'Location','best');
            xlabel(ax,'Time','Interpreter','none');
            ylabel(ax,'BC Pressure [bar]','Interpreter','none');
            title(ax,sprintf('BC Phase %d',i),'Interpreter','none');

            hFigs(end+1,1) = hFig; %#ok<AGROW>
        end
    end
end