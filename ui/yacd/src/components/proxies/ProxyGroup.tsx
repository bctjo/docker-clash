import cx from 'clsx';
import * as React from 'react';
import { ChevronDown, Zap } from 'react-feather';
import { useQuery } from 'react-query';

import * as proxiesAPI from '~/api/proxies';
import { fetchVersion } from '~/api/version';
import {
  getCollapsibleIsOpen,
  getHideUnavailableProxies,
  getLatencyTestUrl,
  getProxySortBy,
} from '~/store/app';
import { fetchProxies, getProxies, switchProxy } from '~/store/proxies';

import Button from '../Button';
import Collapsible from '../Collapsible';
import CollapsibleSectionHeader from '../CollapsibleSectionHeader';
import { connect, useStoreActions } from '../StateProvider';
import { useFilteredAndSorted } from './hooks';
import s0 from './ProxyGroup.module.scss';
import { ProxyList, ProxyListSummaryView } from './ProxyList';

const { useCallback, useMemo, useState } = React;

function ZapWrapper() {
  return (
    <div className={s0.zapWrapper}>
      <Zap size={16} />
    </div>
  );
}

function ProxyGroupImpl({
  name,
  all: allItems,
  delay,
  hideUnavailableProxies,
  proxySortBy,
  proxies,
  type,
  now,
  isOpen,
  latencyTestUrl,
  apiConfig,
  dispatch,
}) {
  const all = useFilteredAndSorted(allItems, delay, hideUnavailableProxies, proxySortBy, proxies);

  const { data: version } = useQuery(['/version', apiConfig], () =>
    fetchVersion('/version', apiConfig)
  );

  const isSelectable = useMemo(
    () => ['Selector', version.meta && 'Fallback', version.meta && 'URLTest'].includes(type),
    [type, version.meta]
  );

  const {
    app: { updateCollapsibleIsOpen },
    proxies: { requestDelayForProxies },
  } = useStoreActions();

  const toggle = useCallback(() => {
    updateCollapsibleIsOpen('proxyGroup', name, !isOpen);
  }, [isOpen, updateCollapsibleIsOpen, name]);

  const itemOnTapCallback = useCallback(
    (proxyName) => {
      if (!isSelectable) return;
      dispatch(switchProxy(apiConfig, name, proxyName));
    },
    [apiConfig, dispatch, name, isSelectable]
  );
  const [isTestingLatency, setIsTestingLatency] = useState(false);
  const testLatency = useCallback(async () => {
    setIsTestingLatency(true);
    try {
      if (version.meta === true) {
        await proxiesAPI.requestDelayForProxyGroup(apiConfig, name, latencyTestUrl);
        await dispatch(fetchProxies(apiConfig));
      } else {
        await requestDelayForProxies(apiConfig, all);
        await dispatch(fetchProxies(apiConfig));
      }
    } catch (err) {}
    setIsTestingLatency(false);
  }, [all, apiConfig, dispatch, name, version.meta, latencyTestUrl, requestDelayForProxies]);

  return (
    <div className={s0.group}>
      <div className={s0.groupHeader}>
        <CollapsibleSectionHeader name={name} type={type} toggle={toggle} qty={all.length} />
        <div className={s0.btnGroup}>
          <Button
            kind="minimal"
            onClick={toggle}
            className={s0.btn}
            title="Toggle collapsible section"
          >
            <span className={cx(s0.arrow, { [s0.isOpen]: isOpen })}>
              <ChevronDown size={20} />
            </span>
          </Button>
          <Button
            title="Test latency"
            kind="minimal"
            onClick={testLatency}
            isLoading={isTestingLatency}
          >
            <ZapWrapper />
          </Button>
        </div>
      </div>
      <Collapsible isOpen={isOpen}>
        <ProxyList
          all={all}
          now={now}
          isSelectable={isSelectable}
          itemOnTapCallback={itemOnTapCallback}
        />
      </Collapsible>
      <Collapsible isOpen={!isOpen}>
        <ProxyListSummaryView
          all={all}
          now={now}
          isSelectable={isSelectable}
          itemOnTapCallback={itemOnTapCallback}
        />
      </Collapsible>
    </div>
  );
}

export const ProxyGroup = connect((s, { name, delay }) => {
  const proxies = getProxies(s);
  const collapsibleIsOpen = getCollapsibleIsOpen(s);
  const proxySortBy = getProxySortBy(s);
  const hideUnavailableProxies = getHideUnavailableProxies(s);
  const latencyTestUrl = getLatencyTestUrl(s);

  const group = proxies[name];
  const { all, type, now } = group;
  return {
    all,
    delay,
    hideUnavailableProxies,
    proxySortBy,
    proxies,
    type,
    now,
    isOpen: collapsibleIsOpen[`proxyGroup:${name}`],
    latencyTestUrl,
  };
})(ProxyGroupImpl);
