clc
clear


Data1 = extract_fig('Malfunction H 2_update_new.fig');
Data2 = extract_fig('ManualBrakeCompare3.fig');

% --- pick curve 0x6e from Data1 (your example uses index 4) ---
x_6e = Data1(4).x(:);
y_6e = Data1(4).y(:);

% --- Data2: choose which line to compare ---
% If ManualBrakeCompare.fig has only one curve:
x_real = Data2(1).x(:);
y_real = Data2(1).y(:);

% ---- Filter ONLY Data1 ----
out = filter_10hz(x_6e, y_6e, ...
    'Fc', 10, ...
    'FilterOrder', 1, ...
    'MA_Window', 5);
y_f = out.y_butter(:);

% ---- Find FIRST crossing of 0.05 (Data1 filtered) ----
idx0 = find(y_f >= 0.05, 1, 'first');

% ---- Find FIRST crossing of 0.4 AFTER idx0 (Data1 filtered) ----
idx1 = find(y_f(idx0:end) >= 0.4, 1, 'first');
idx1 = idx0 + idx1 - 1;

% ---- Crop Data1 to the lag window [0.05 .. first 0.4] ----
x_lag = x_6e(idx0:idx1);
y_lag = y_f(idx0:idx1);

% ---- Relative time for Data1 (aligned at 0.05 crossing) ----
t_rel_1 = seconds(x_lag - x_lag(1));

% ---- Relative time for Data2 (aligned at its start) ----
t_rel_2 = seconds(x_real - x_real(1));

% ---- Plot comparison ----
figure; hold on; grid on
plot(t_rel_1, y_lag, 'LineWidth', 1.8, 'DisplayName', '0x6e (filtered 10 Hz, 0.05→0.4)');
plot(t_rel_2, y_real, '--', 'LineWidth', 1.8, 'DisplayName', 'Real (raw)');

xlabel('t_{rel} [s]')
ylabel('BC Pressure [bar]')
title('Direct time-history comparison')
legend('Location','best')
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Functions

function Data = extract_fig(figFile)
% extract_fig
%
% Opens a MATLAB .fig file and extracts all line objects.
%
% OUTPUT:
%   Data(i).Name
%   Data(i).x
%   Data(i).y
%
% No filtering. No processing.

    fig = openfig(figFile, 'invisible');
    allAxes = findall(fig, 'Type', 'axes');

    Data = struct('Name',{},'x',{},'y',{});
    counter = 0;

    for axIdx = 1:length(allAxes)
        ax = allAxes(axIdx);
        lines = findall(ax, 'Type', 'line');

        for lineIdx = 1:length(lines)

            line = lines(lineIdx);
            x = get(line, 'XData');
            y = get(line, 'YData');

            if isempty(x) || isempty(y)
                continue
            end

            % If numeric datenum, convert to datetime
            if isnumeric(x)
                try
                    x = datetime(x, 'ConvertFrom', 'datenum');
                catch
                    % if not convertible, leave numeric
                end
            end

            name = get(line,'DisplayName');
            if isempty(name)
                name = sprintf('Ax%d_Line%d',axIdx,lineIdx);
            end

            counter = counter + 1;
            Data(counter).Name = name;
            Data(counter).x    = x(:);
            Data(counter).y    = y(:);

        end
    end

    close(fig);
end


function out = filter_10hz(x, y, varargin)
%filter_10hz Causal moving average + 10 Hz Butterworth for (datetime x, double y).
%
% Inputs:
%   x : Nx1 datetime
%   y : Nx1 double
%
% Name-value:
%   'Fc'          : cutoff frequency [Hz], default 10
%   'FilterOrder' : Butterworth order, default 1 (matches your 2-coefficient recursion)
%   'MA_Window'   : moving-average window length [samples], default 5
%
% Output struct out:
%   out.Fs, out.dt, out.y_ma, out.y_butter

    p = inputParser;
    addParameter(p,'Fc',10,@(v)isnumeric(v)&&isscalar(v)&&v>0);
    addParameter(p,'FilterOrder',1,@(v)isnumeric(v)&&isscalar(v)&&v>=1);
    addParameter(p,'MA_Window',5,@(v)isnumeric(v)&&isscalar(v)&&v>=1);
    parse(p,varargin{:});

    Fc          = p.Results.Fc;
    filterOrder = p.Results.FilterOrder;
    winMA       = p.Results.MA_Window;

    % --- basic checks ---
    x = x(:); y = y(:);

    % --- sampling estimate from datetime ---
    dtv = seconds(diff(x));
    dtv = dtv(isfinite(dtv) & dtv > 0);
    dt = median(dtv);
    Fs = 1/dt;

    % --- moving average (pre-smoothing) ---
    % causal moving average (like your buffer loop)
    y_ma = causal_moving_average(y, winMA);

    % --- butterworth design ---
    Wn = Fc/(Fs/2);
    if Wn >= 1
        error('Cutoff Fc=%.3g Hz is too high for Fs=%.3g Hz (Fc must be < Fs/2).', Fc, Fs);
    end
    [b,a] = butter(filterOrder, Wn);

    % --- filtering ---
    % causal IIR filtering
    % If filterOrder==1, this matches your explicit recursion.
    % For higher order, filter() is the correct causal implementation.
    y_butter = filter(b, a, y_ma);

    out = struct();
    out.Fs = Fs;
    out.dt = dt;
    out.Fc = Fc;
    out.FilterOrder = filterOrder;
    out.MA_Window = winMA;
    out.y_ma = y_ma;
    out.y_butter = y_butter;
end

function y_ma = causal_moving_average(y, win)
    y = y(:);
    N = numel(y);
    y_ma = zeros(N,1);

    buf = zeros(win,1);
    s = 0;
    idx = 1;

    for k = 1:N
        newVal = y(k);
        if ~isfinite(newVal)
            newVal = 0; %
        end
        s = s - buf(idx) + newVal;
        buf(idx) = newVal;
        idx = mod(idx, win) + 1;
        y_ma(k) = s / min(k, win);
    end
end