function export_nodo_summary(matFile, outCsv)
%EXPORT_NODO_SUMMARY Summarize a MATLAB Nodo_*.mat file to CSV for cross-checking
%   against the Python port's output (see python_port/tools/compare_summaries.py).
%
%   export_nodo_summary('data/interim/Dati10/Nodo_Dati10_20260115_20260116.mat', ...
%                        'python_port/tools/_matlab_summary.csv')
%
%   Writes one row per sensor: ID, Label, NumSamples, FirstTime, LastTime,
%   MeanPressure, StdPressure, MinPressure, MaxPressure.

if nargin < 2
    [d, b, ~] = fileparts(matFile);
    outCsv = fullfile(d, [b '_summary.csv']);
end

S = load(matFile);
if isfield(S, 'Nodo')
    Nodo = S.Nodo;
elseif isfield(S, 'Nodo_filtered')
    Nodo = S.Nodo_filtered;
else
    error('export_nodo_summary:MissingVar', 'File has neither Nodo nor Nodo_filtered.');
end

n = numel(Nodo);
ID = strings(n,1); Label = strings(n,1);
NumSamples = zeros(n,1);
FirstTime = strings(n,1); LastTime = strings(n,1);
MeanPressure = nan(n,1); StdPressure = nan(n,1);
MinPressure = nan(n,1); MaxPressure = nan(n,1);

for k = 1:n
    ID(k) = string(Nodo(k).ID);
    Label(k) = string(Nodo(k).Label);
    p = Nodo(k).Pressure;
    t = Nodo(k).Time;
    NumSamples(k) = numel(p);
    if ~isempty(t)
        FirstTime(k) = string(datestr(t(1), 'yyyy-mm-ddTHH:MM:SS.FFF'));
        LastTime(k)  = string(datestr(t(end), 'yyyy-mm-ddTHH:MM:SS.FFF'));
    end
    if ~isempty(p)
        MeanPressure(k) = mean(p);
        StdPressure(k)  = std(p);
        MinPressure(k)  = min(p);
        MaxPressure(k)  = max(p);
    end
end

T = table(ID, Label, NumSamples, FirstTime, LastTime, MeanPressure, StdPressure, MinPressure, MaxPressure);
writetable(T, outCsv);
fprintf('Wrote summary for %d sensors to %s\n', n, outCsv);
end
