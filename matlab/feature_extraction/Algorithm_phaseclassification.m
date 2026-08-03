function TBsets_out = Algorithm_phaseclassification(TBsets, varargin)
% DETECT_SUBPHASES_SETS
% Apply BOTH:
%   - detect_MBP_pipe_subphases
%   - detect_BC_cyl_subphases
% to each cell of a 1xN (or MxN) cell array of TestBrake struct arrays.
%
% Inputs
%   TBsets    : cell array; each cell is a 1xK TestBrake struct array
%   Name-Value pairs (wrapper params + args forwarded to detectors):
%     'UseParfor'  (false)  : run cells in parallel (Parallel Toolbox)
%     'Verbose'    (false)  : print per-cell progress
%     'MBPArgs'    ({})     : cell array of name/value pairs for detect_MBP_pipe_subphases
%     'BCArgs'     ({})     : cell array of name/value pairs for detect_BC_cyl_subphases
%
% Output
%   TBsets_out: same size as TBsets, each cell post-processed by both detectors.

    assert(iscell(TBsets), 'TBsets must be a cell array of TestBrake structs.');
    sz = size(TBsets);
    TB_row = TBsets(:).';               % row vector for iteration
    nC = numel(TB_row);

    % ---- parse wrapper options
    ip = inputParser;
    addParameter(ip,'UseParfor', false, @islogical);
    addParameter(ip,'Verbose',   false, @islogical);
    addParameter(ip,'MBPArgs',   {},    @(x) iscell(x));
    addParameter(ip,'BCArgs',    {},    @(x) iscell(x));
    parse(ip, varargin{:});
    useParfor = ip.Results.UseParfor;
    verbose   = ip.Results.Verbose;
    mbpArgs   = ip.Results.MBPArgs;
    bcArgs    = ip.Results.BCArgs;

    TB_out_row = cell(1, nC);

    if useParfor
        % Parallel loop (requires Parallel Computing Toolbox)
        parfor c = 1:nC
            TB_out_row{c} = process_each_cell(TB_row{c}, mbpArgs, bcArgs, verbose, c);
        end
    else
        for c = 1:nC
            TB_out_row{c} = process_each_cell(TB_row{c}, mbpArgs, bcArgs, verbose, c);
        end
    end

    TBsets_out = reshape(TB_out_row, sz);
end

% ---------- local helpers ----------
function Sout = process_each_cell(Sin, mbpArgs, bcArgs, verbose, idx)
    % Pass-through for empty/non-struct cells
    if isempty(Sin)
        if verbose, fprintf('[%d] empty cell → passthrough\n', idx); end
        Sout = Sin;
        return;
    end
    if ~isstruct(Sin)
        if verbose, fprintf('[%d] non-struct cell → passthrough\n', idx); end
        Sout = Sin;
        return;
    end

    S = Sin;
    % 1) MBP pipe subphases
    try
        S = detect_MBP_pipe_subphases(S, mbpArgs{:});
        if verbose, fprintf('[%d] MBP done (%d phases)\n', idx, numel(S)); end
    catch ME
        if verbose
            fprintf('[%d] MBP ERROR: %s (leaving MBP step as-is)\n', idx, ME.message);
            for s = 1:numel(ME.stack)
                fprintf('  -> %s (line %d)\n', ME.stack(s).name, ME.stack(s).line);
            end
        end
        % keep S unchanged
    end

    % 2) BC cylinder subphases
    try
        S = detect_BC_cyl_subphases(S, bcArgs{:});
        if verbose, fprintf('[%d] BC  done (%d phases)\n', idx, numel(S)); end
    catch ME
        if verbose, fprintf('[%d] BC  ERROR: %s (leaving BC step as-is)\n', idx, ME.message); 
            for s = 1:numel(ME.stack)
                fprintf('  -> %s (line %d)\n', ME.stack(s).name, ME.stack(s).line);
            end
        end
        % keep S as after MBP
    end

    Sout = S;
end
